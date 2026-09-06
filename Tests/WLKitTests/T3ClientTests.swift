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

    func testSidebarOrderUsesPinsManualPositionsAndCreationInsteadOfActivity() throws {
        let sessions = try parse([
            thread("manual-b", extra: ["activeOrderKey": "b", "latestUserMessageAt": "2026-09-07T12:00:00Z"]),
            thread("pin-new", extra: ["pinnedAt": "yes", "createdAt": "2026-09-06T12:00:00Z"]),
            thread("new", extra: ["createdAt": "2026-09-06T10:00:00Z"]),
            thread("manual-a", extra: ["activeOrderKey": "a"]),
            thread("pin-b", extra: ["pinnedAt": "yes", "pinOrderKey": "b"]),
            thread("old", extra: ["createdAt": "2026-09-05T12:00:00Z", "latestUserMessageAt": "2026-09-08T12:00:00Z"]),
            thread("reopened", extra: ["createdAt": "2026-09-01T12:00:00Z", "unsettledAt": "2026-09-06T11:00:00Z"]),
            thread("pin-a", extra: ["pinnedAt": "yes", "pinOrderKey": "a"]),
            thread("pin-old", extra: ["pinnedAt": "yes", "createdAt": "2026-09-05T12:00:00Z"]),
            thread("settled", extra: ["settledOverride": "settled", "pinnedAt": "yes"]),
        ])
        XCTAssertEqual(SessionAssignments.orderedByProvider(sessions).map(\.id),
                       ["pin-a", "pin-b", "pin-new", "pin-old", "reopened", "new", "old", "manual-a", "manual-b"])
        XCTAssertEqual(sessions.count, 10)
        XCTAssertNil(sessions.first { $0.id == "settled" }?.providerOrder)
    }

    func testSidebarSnoozeMatchesExpiryAndAttentionWakeRules() throws {
        let before = "2026-09-06T10:00:00Z", snoozed = "2026-09-06T11:00:00Z", after = "2026-09-06T11:30:00Z"
        let inputs: [[String: Any]] = [
            thread("sleeping", session: "running"),
            thread("expired", extra: ["snoozedUntil": before]),
            thread("invalid-wake", extra: ["snoozedUntil": "invalid"]),
            thread("approval", extra: ["hasPendingApprovals": true]),
            thread("question", extra: ["hasPendingUserInput": true]),
            thread("fresh-error", extra: ["session": ["status": "error", "updatedAt": after]]),
            thread("old-error", extra: ["session": ["status": "error", "updatedAt": before]]),
            thread("fresh-completion", extra: ["latestTurn": ["state": "completed", "completedAt": after]]),
            thread("old-completion", extra: ["latestTurn": ["state": "completed", "completedAt": before]]),
        ].map { value in
            var result: [String: Any] = ["snoozedAt": snoozed, "snoozedUntil": "2026-09-06T14:00:00Z"]
            result.merge(value) { _, value in value }
            return result
        }
        let data = try JSONSerialization.data(withJSONObject: ["threads": inputs, "projects": []])
        let now = ISO8601DateFormatter().date(from: "2026-09-06T12:00:00Z")!
        let sessions = try T3Client.parseShell(data: data, environmentID: "env", now: now)
        XCTAssertEqual(Set(SessionAssignments.orderedByProvider(sessions).map(\.id)),
                       Set(["expired", "invalid-wake", "approval", "question", "fresh-error", "fresh-completion"]))
    }

    func testSidebarDatesUseInstantsAndDeterministicFallbacks() throws {
        let sessions = try parse([
            thread("newest", extra: ["createdAt": "2026-09-06T12:00:00.500Z"]),
            thread("older-offset", extra: ["createdAt": "2026-09-06T14:00:00+02:00"]),
            thread("b-missing"),
            thread("a-invalid", extra: ["createdAt": "invalid"]),
        ])
        XCTAssertEqual(SessionAssignments.orderedByProvider(sessions).map(\.id),
                       ["newest", "older-offset", "a-invalid", "b-missing"])
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

    @MainActor func testPollingReadsNewStatusDespiteCacheableResponses() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
        import json
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class Handler(BaseHTTPRequestHandler):
            count = 0
            def do_GET(self):
                Handler.count += 1
                working = Handler.count == 1
                body = json.dumps({"projects": [], "threads": [{
                    "id": "session", "projectId": "project", "title": "Live status",
                    "updatedAt": "2026-09-06T12:00:00Z",
                    "session": {"status": "running" if working else "ready"},
                    "latestTurn": {"state": "running" if working else "completed"},
                    "hasPendingApprovals": False, "hasPendingUserInput": False
                }]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "max-age=3600")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args): pass
        server = HTTPServer(("127.0.0.1", 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """]
        let output = Pipe()
        server.standardOutput = output
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        var portData = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
            portData.append(byte)
        }
        guard let portText = String(data: portData, encoding: .utf8), let port = Int(portText) else {
            XCTFail("Cache fixture did not start"); return
        }
        var settings = T3ConnectionSettings()
        settings.baseURL = "http://127.0.0.1:\(port)"
        settings.environmentID = "env"
        let client = T3Client(settings: settings)
        let first = try await client.listSessions()
        let second = try await client.listSessions()
        XCTAssertEqual(first.first?.status, .working)
        XCTAssertEqual(second.first?.status, .done)
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
