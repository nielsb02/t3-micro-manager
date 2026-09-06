import Foundation
import XCTest
@testable import WLKit

final class T3ClientTests: XCTestCase {
    func testApprovalAndInputOverrideRunningAndFailure() throws {
        XCTAssertEqual(try parse([thread("plan", session: "running", extra: ["hasActionableProposedPlan": true])]).first?.status, .blocked)
        let sessions = try parse([
            thread("approval", session: "running", turn: "running", extra: ["hasPendingApprovals": true]),
            thread("input", session: "error", extra: ["hasPendingUserInput": true]),
        ])
        XCTAssertEqual(sessions.map(\.status), [.blocked, .blocked])
    }

    func testBackgroundWorkAndMonitoringStayWorkingAfterTurnCompletes() throws {
        let sessions = try parse([
            thread("background", session: "ready", turn: "completed", extra: ["backgroundLiveness": "working"]),
            thread("monitor", session: "idle", turn: "completed", extra: ["backgroundLiveness": "monitoring"]),
            thread("failure", session: "error", extra: ["backgroundLiveness": "working"]),
        ])
        XCTAssertEqual(sessions.map(\.status), [.working, .working, .error])
    }

    func testStartingCompletionTeardownAndIdleStates() throws {
        let sessions = try parse([
            thread("starting", session: "starting"),
            thread("running", turn: "running"),
            thread("done", turn: "completed"),
            thread("ready", session: "ready"),
            thread("idle-session", session: "idle"),
            thread("finished-before-teardown", session: "stopped", turn: "interrupted", extra: [
                "latestTurn": ["state": "interrupted", "completedAt": "2026-09-06T12:00:00Z"],
            ]),
            thread("interrupted", session: "interrupted", turn: "interrupted"),
            thread("new"),
            thread("future", session: "new-version-state"),
        ])
        XCTAssertEqual(sessions.map(\.status), [.working, .working, .done, .idle, .idle, .idle, .idle, .idle, .unknown])
    }

    func testSessionMetadataUsesMeaningfulActivityAndWorktreeDirectory() throws {
        let sessions = try parse([
            thread("pinned", extra: ["pinnedAt": "2026-09-06T10:00:00Z", "worktreePath": "/work/tree",
                                     "latestUserMessageAt": "2026-09-06T11:00:00Z"]),
            thread("normal"),
            thread("archived", extra: ["archivedAt": "2026-09-06T10:00:00Z"]),
            thread("deleted", extra: ["deletedAt": "2026-09-06T10:00:00Z"]),
        ])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].environmentID, "local-env")
        XCTAssertEqual(sessions[0].directory, "/work/tree")
        XCTAssertTrue(sessions[0].isPinned)
        XCTAssertEqual(sessions[0].updatedAt, "2026-09-06T11:00:00Z")
        XCTAssertEqual(sessions[1].directory, "/work/project")
        XCTAssertFalse(sessions[1].isPinned)
    }

    func testMalformedAndDuplicateSnapshotsFailInsteadOfClearingThePad() throws {
        XCTAssertThrowsError(try T3Client.parseShell(data: Data("{}".utf8), environmentID: "env"))
        XCTAssertThrowsError(try parse([thread("duplicate"), thread("duplicate")]))
        var malformed = thread("incomplete")
        malformed.removeValue(forKey: "hasPendingApprovals")
        XCTAssertThrowsError(try parse([malformed]))
        XCTAssertTrue(try parse([]).isEmpty)
    }

    func testCompletionIdentityTracksTurnsIndependentlyOfSessionMetadata() throws {
        let first = try parse([thread("thread", turn: "completed", extra: [
            "latestTurn": ["turnId": "turn-1", "state": "completed"],
        ])])[0]
        let edited = try parse([thread("thread", turn: "completed", extra: [
            "title": "Renamed", "updatedAt": "later", "pinnedAt": "later",
            "latestTurn": ["turnId": "turn-1", "state": "completed"],
        ])])[0]
        let next = try parse([thread("thread", turn: "completed", extra: [
            "latestTurn": ["turnId": "turn-2", "state": "completed"],
        ])])[0]
        XCTAssertEqual(first.completionID, edited.completionID)
        XCTAssertFalse(first.completionID == next.completionID)
    }

    func testDiscoveryOnlyAcceptsLocalRuntimeMetadataAndPrefersDevWebOrigin() throws {
        func endpoint(_ origin: String, dev: String? = nil) throws -> String? {
            var metadata: [String: Any] = ["version": 1, "origin": origin]
            if let dev { metadata["devUrl"] = dev }
            return T3Client.localEndpoint(from: try JSONSerialization.data(withJSONObject: metadata))
        }
        XCTAssertEqual(try endpoint("http://127.0.0.1:3773"), "http://127.0.0.1:3773")
        XCTAssertEqual(try endpoint("http://127.0.0.1:3773", dev: "http://localhost:5173"), "http://localhost:5173")
        XCTAssertNil(try endpoint("http://remote.example:3773"))
        XCTAssertNil(try endpoint("http://localhost:3773?token=secret"))
        XCTAssertNil(try endpoint("http://name:secret@localhost:3773"))
    }

    @MainActor func testThreadURLPreservesIdentityAndNeverIncludesTheCredential() throws {
        var settings = T3ConnectionSettings()
        settings.baseURL = "http://127.0.0.1:3773/"
        settings.bearerToken = "do-not-expose"
        let client = T3Client(settings: settings)
        let url = try client.sessionURL(AgentSession(id: "thread/one?#", title: "Example", status: .done, environmentID: "env space"))
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:3773/env%20space/thread%2Fone%3F%23")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)
        XCTAssertThrowsError(try client.sessionURL(AgentSession(id: "one", title: "Example", status: .idle)))
    }

    @MainActor func testPairingLinkExchangeThenAuthenticatedShellLoad() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T3TestURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel(); T3TestURLProtocol.handler = nil }
        let fixture = try shellData([thread("example", session: "running")])
        var discoveryCount = 0
        T3TestURLProtocol.handler = { request in
            switch request.url!.path {
            case "/oauth/token":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    var data = Data()
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                    body = data
                }
                let form = URLComponents(string: "?" + String(data: body ?? Data(), encoding: .utf8)!)!
                let fields = Dictionary(form.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
                XCTAssertEqual(fields["subject_token"], "pairing+token&value")
                XCTAssertEqual(fields["scope"], "orchestration:read")
                XCTAssertEqual(fields["grant_type"], "urn:ietf:params:oauth:grant-type:token-exchange")
                return (200, Data(#"{"access_token":"owned-credential","token_type":"Bearer","scope":"orchestration:read"}"#.utf8))
            case "/.well-known/t3/environment":
                discoveryCount += 1
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, Data(#"{"environmentId":"actual-local-env"}"#.utf8))
            case "/api/orchestration/shell":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owned-credential")
                return (200, fixture)
            default: throw T3Error.badResponse
            }
        }
        let client = T3Client(settings: T3ConnectionSettings(), transport: transport)
        let token = try await client.pair(code: "http://127.0.0.1:3773/pair#token=pairing%2Btoken%26value")
        XCTAssertEqual(token, "owned-credential")
        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.first?.environmentID, "actual-local-env")
        XCTAssertEqual(sessions.first?.status, .working)
        _ = try await client.listSessions()
        XCTAssertEqual(discoveryCount, 1)
    }

    @MainActor func testAuthorizationFailureDoesNotExposeResponseBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T3TestURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel(); T3TestURLProtocol.handler = nil }
        T3TestURLProtocol.handler = { _ in (401, Data("sensitive-server-response".utf8)) }
        var settings = T3ConnectionSettings()
        settings.environmentID = "env"
        let client = T3Client(settings: settings, transport: transport)
        do {
            _ = try await client.listSessions()
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pair"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-server-response"))
        }
    }

    private func thread(_ id: String, session: String? = nil, turn: String? = nil,
                        extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = [
            "id": id, "projectId": "project", "title": "Session \(id)",
            "updatedAt": "2026-09-06T12:00:00Z", "hasPendingApprovals": false, "hasPendingUserInput": false,
        ]
        if let session { value["session"] = ["status": session] }
        if let turn { value["latestTurn"] = ["state": turn] }
        return value.merging(extra, uniquingKeysWith: { _, new in new })
    }

    private func shellData(_ threads: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "threads": threads, "projects": [["id": "project", "workspaceRoot": "/work/project"]],
        ])
    }

    private func parse(_ threads: [[String: Any]]) throws -> [AgentSession] {
        try T3Client.parseShell(data: shellData(threads), environmentID: "local-env")
    }
}

private final class T3TestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
