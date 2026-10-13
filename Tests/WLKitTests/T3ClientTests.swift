import Foundation
import XCTest
@testable import WLKit

final class T3ClientTests: XCTestCase {
    func testRealV2ShellFixtureMapsEachStatus() throws {
        let sessions = try T3Client.parseShell(data: fixtureData("t3-shell-v2.json"), environmentID: "local-env")
        func status(_ id: String) -> SessionStatus? { sessions.first { $0.id == id }?.status }
        XCTAssertEqual(sessions.count, 6)
        XCTAssertEqual(status("thread-1"), .idle)
        XCTAssertEqual(status("thread-2"), .working)
        XCTAssertEqual(status("thread-3"), .blocked)
        XCTAssertEqual(status("thread-4"), .error)
        XCTAssertEqual(status("thread-5"), .done)
        XCTAssertEqual(status("thread-6"), .working)
        let completed = sessions.first { $0.id == "thread-5" }
        XCTAssertEqual(completed?.title, "Fixture thread 5")
        XCTAssertEqual(completed?.directory, "/tmp/fixture/worktree-5")
        XCTAssertEqual(completed?.completionID, "run-5")
        XCTAssertEqual(completed?.updatedAt, "2026-09-22T16:18:34.408Z")
        XCTAssertEqual(completed?.environmentID, "local-env")
    }

    func testPendingRuntimeRequestOverridesRunningAndFailure() throws {
        let request: [String: Any] = ["id": "request", "kind": "user_input", "createdAt": "2026-10-09T12:00:00.000Z"]
        let sessions = try parse([
            thread("approval", status: "running", extra: ["pendingRuntimeRequest": request]),
            thread("input", status: "failed", extra: ["pendingRuntimeRequest": request]),
            thread("none", status: "running", extra: ["pendingRuntimeRequest": NSNull()]),
        ])
        XCTAssertEqual(sessions.map(\.status), [.blocked, .blocked, .working])
    }

    func testProposedPlanBlocksOnlyInPlanModeWhenNoRunIsActive() throws {
        let sessions = try parse([
            thread("plan", extra: ["hasActionableProposedPlan": true, "interactionMode": "plan"]),
            thread("default-mode", extra: ["hasActionableProposedPlan": true, "interactionMode": "default"]),
            thread("no-plan", extra: ["hasActionableProposedPlan": false, "interactionMode": "plan"]),
            thread("running-plan", status: "running", extra: ["hasActionableProposedPlan": true, "interactionMode": "plan"]),
        ])
        XCTAssertEqual(sessions.map(\.status), [.blocked, .idle, .idle, .working])
    }

    func testActiveRunStatesWorkAndFailuresError() throws {
        var threads: [[String: Any]] = []
        for state in ["preparing", "queued", "starting", "running", "waiting"] { threads.append(thread(state, status: state)) }
        threads.append(thread("failed", status: "failed"))
        threads.append(thread("usage-limit", status: "failed",
                              extra: ["lastErrorClass": "usage_limit", "usageLimitResetAt": "2026-10-10T00:00:00.000Z"]))
        let sessions = try parse(threads)
        XCTAssertEqual(sessions.map(\.status), [.working, .working, .working, .working, .working, .error, .error])
    }

    func testCompletionAndRestingStates() throws {
        let sessions = try parse([
            thread("completed", status: "completed"),
            thread("idle", status: "idle"),
            thread("cancelled", status: "cancelled"),
            thread("interrupted", status: "interrupted"),
            thread("rolled-back", status: "rolled_back"),
            thread("future", status: "new-version-state"),
        ])
        XCTAssertEqual(sessions.map(\.status), [.done, .idle, .idle, .idle, .idle, .idle])
    }

    func testSubagentThreadsAreExcludedLikeTheDesktopFeed() throws {
        let sessions = try parse([
            thread("parent", status: "running", extra: ["lineage": lineage(parent: nil, relationship: nil)]),
            thread("child", status: "running", extra: ["lineage": lineage(parent: "parent", relationship: "subagent")]),
            thread("fork", status: "running", extra: ["lineage": lineage(parent: "parent", relationship: "fork")]),
            thread("side-chat", status: "running",
                   extra: ["lineage": lineage(parent: "parent", relationship: "fork"), "sideChat": true]),
            thread("unknown-lineage"),
        ])
        XCTAssertEqual(sessions.map(\.id), ["parent", "fork", "unknown-lineage"])
        XCTAssertNil(sessions.first { $0.id == "child" })
    }

    func testOpenSideChatsLiftTheirMainThreadsStatus() throws {
        func sideChat(_ id: String, status: String, extra: [String: Any] = [:]) -> [String: Any] {
            thread(id, status: status, extra: [
                "lineage": lineage(parent: "main", relationship: "fork"), "sideChat": true,
            ].merging(extra, uniquingKeysWith: { _, new in new }))
        }
        func mainStatus(_ sideChats: [[String: Any]]) throws -> SessionStatus? {
            try parse([thread("main", status: "completed")] + sideChats).first { $0.id == "main" }?.status
        }
        XCTAssertEqual(try mainStatus([]), .done)
        XCTAssertEqual(try mainStatus([sideChat("side-working", status: "running")]), .working)
        XCTAssertEqual(try mainStatus([
            sideChat("side-working", status: "running"),
            sideChat("side-asking", status: "running", extra: ["pendingRuntimeRequest": ["id": "request"]]),
        ]), .blocked)
        // Closed and finished side chats leave the main thread's own status alone.
        XCTAssertEqual(try mainStatus([
            sideChat("side-closed", status: "running", extra: ["archivedAt": "2026-09-06T10:00:00Z"]),
            sideChat("side-done", status: "completed"),
        ]), .done)
        XCTAssertEqual(try parse([thread("main"), sideChat("side-working", status: "running")]).map(\.id), ["main"])
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
        malformed.removeValue(forKey: "status")
        XCTAssertThrowsError(try parse([malformed]))
        XCTAssertThrowsError(try T3Client.parseShell(data: Data(#"{"schemaVersion":1,"threads":[],"projects":[]}"#.utf8), environmentID: "env"))
        XCTAssertThrowsError(try T3Client.parseShell(data: Data(#"{"schemaVersion":2,"threads":{},"projects":[]}"#.utf8), environmentID: "env"))
        XCTAssertThrowsError(try T3Client.parseShell(data: Data("[]".utf8), environmentID: "env"))
        XCTAssertTrue(try parse([]).isEmpty)
        // Unknown and missing optional fields stay decodable.
        let lenient = Data(#"{"threads":[{"id":"a","projectId":"p","title":"A","status":"idle","futureField":{"x":1}}],"projects":[]}"#.utf8)
        XCTAssertEqual(try T3Client.parseShell(data: lenient, environmentID: "env").map(\.status), [.idle])
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
        let request: [String: Any] = ["id": "request", "kind": "approval", "createdAt": after]
        let inputs: [[String: Any]] = [
            thread("sleeping", status: "running"),
            thread("expired", extra: ["snoozedUntil": before]),
            thread("invalid-wake", extra: ["snoozedUntil": "invalid"]),
            thread("approval", extra: ["pendingRuntimeRequest": request]),
            thread("question", status: "running", extra: ["pendingRuntimeRequest": request]),
            thread("fresh-error", status: "failed", extra: ["updatedAt": after]),
            thread("old-error", status: "failed", extra: ["updatedAt": before]),
            thread("fresh-completion", status: "completed", extra: ["latestRunCompletedAt": after]),
            thread("old-completion", status: "completed", extra: ["latestRunCompletedAt": before]),
        ].map { value in
            var result: [String: Any] = ["snoozedAt": snoozed, "snoozedUntil": "2026-09-06T14:00:00Z"]
            result.merge(value) { _, value in value }
            return result
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "threads": inputs, "projects": []])
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

    func testCompletionIdentityTracksRunsIndependentlyOfThreadMetadata() throws {
        let first = try parse([thread("thread", status: "completed", extra: ["latestRunId": "run-1"])])[0]
        let edited = try parse([thread("thread", status: "completed", extra: [
            "title": "Renamed", "updatedAt": "later", "pinnedAt": "later", "latestRunId": "run-1",
        ])])[0]
        let next = try parse([thread("thread", status: "completed", extra: ["latestRunId": "run-2"])])[0]
        let byTime = try parse([thread("thread", status: "completed", extra: ["latestRunCompletedAt": "2026-09-06T12:30:00Z"])])[0]
        XCTAssertEqual(first.completionID, edited.completionID)
        XCTAssertFalse(first.completionID == next.completionID)
        XCTAssertEqual(byTime.completionID, "2026-09-06T12:30:00Z")
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
        let fixture = try shellData([thread("example", status: "running")])
        var discoveryCount = 0
        T3TestURLProtocol.handler = { request in
            switch request.url!.path {
            case "/oauth/token":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "x-t3-orchestration-protocol"))
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
                XCTAssertNil(request.value(forHTTPHeaderField: "x-t3-orchestration-protocol"))
                return (200, Data(#"{"environmentId":"actual-local-env"}"#.utf8))
            case "/api/orchestration/shell":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owned-credential")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-t3-orchestration-protocol"), "2")
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
                if self.headers.get("x-t3-orchestration-protocol") != "2":
                    self.send_response(400)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                Handler.count += 1
                working = Handler.count == 1
                body = json.dumps({"schemaVersion": 2, "snapshotSequence": Handler.count, "projects": [], "archivedThreads": [], "threads": [{
                    "id": "session", "projectId": "project", "title": "Live status",
                    "updatedAt": "2026-09-06T12:00:00Z",
                    "status": "running" if working else "completed",
                    "activeRunId": "run" if working else None, "latestRunId": "run",
                    "pendingRuntimeRequest": None, "hasActionableProposedPlan": False
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

    private func thread(_ id: String, status: String = "idle", extra: [String: Any] = [:]) -> [String: Any] {
        let value: [String: Any] = [
            "id": id, "projectId": "project", "title": "Session \(id)", "status": status,
            "updatedAt": "2026-09-06T12:00:00Z", "pendingRuntimeRequest": NSNull(),
            "hasActionableProposedPlan": false, "interactionMode": "default",
        ]
        return value.merging(extra, uniquingKeysWith: { _, new in new })
    }

    private func lineage(parent: String?, relationship: String?) -> [String: Any] {
        func json(_ value: String?) -> Any {
            if let value = value { return value }
            return NSNull()
        }
        return ["parentThreadId": json(parent), "relationshipToParent": json(relationship), "rootThreadId": parent ?? "root"]
    }

    private func shellData(_ threads: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "snapshotSequence": 1, "archivedThreads": [],
            "threads": threads, "projects": [["id": "project", "workspaceRoot": "/work/project"]],
        ])
    }

    /// Fixtures live beside the tests; verify-t3.sh compiles this file elsewhere and sets the directory.
    private func fixtureData(_ name: String) throws -> Data {
        let directory = ProcessInfo.processInfo.environment["T3_FIXTURE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        return try Data(contentsOf: directory.appendingPathComponent(name))
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
