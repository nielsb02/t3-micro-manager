import Foundation
import XCTest
@testable import WLKit

@MainActor final class CmuxClientTests: XCTestCase {
    private let window = "10000000-0000-0000-0000-000000000001"
    private let workspace = "20000000-0000-0000-0000-000000000001"
    private let otherWorkspace = "20000000-0000-0000-0000-000000000002"
    private let terminal = "30000000-0000-0000-0000-000000000001"
    private let otherTerminal = "30000000-0000-0000-0000-000000000002"
    private let browser = "30000000-0000-0000-0000-000000000003"

    func testMinimumVersionRejectsOlderAndUnparseableVersions() throws {
        for version in ["cmux 0.64.22 (102) [ddd4a01bc]", "cmux 0.64.23", "cmux 0.65.0", "cmux 1.0.0"] {
            XCTAssertNoThrow(try CmuxClient.requireSupportedVersion(version))
        }
        for version in ["cmux 0.62.2", "cmux 0.64.21", "cmux 0.64.22-beta", "cmux nightly", "unknown", "0.64.22"] {
            XCTAssertThrowsError(try CmuxClient.requireSupportedVersion(version)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Update cmux to 0.64.22"))
            }
        }
    }

    func testOldVersionNeverContactsSocket() async throws {
        let fixture = try makeFixture()
        await fixture.setVersion("cmux 0.62.2")
        let client = CmuxClient(settings: .init(), command: fixture.run)
        do { _ = try await client.listSessions(); XCTFail("Old cmux accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("0.64.22")) }
        let commands = await fixture.commands
        XCTAssertEqual(commands, [["--version"]])
    }

    func testNewCLIWithOldRunningServerIsRejected() async throws {
        let fixture = try makeFixture()
        await fixture.setCapabilities(["workspace.select", "notification.list"])
        let client = CmuxClient(settings: .init(), command: fixture.run)
        do { _ = try await client.listSessions(); XCTFail("Old server accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("restart it")) }
        let commands = await fixture.commands
        XCTAssertFalse(commands.contains { $0.contains("system.tree") || $0.first == "sessions" })
    }

    func testWorkspaceAggregationKeepsSeparateAgentsAndIgnoresNonAgentBrowser() async throws {
        let fixture = try makeFixture(hooks: [hook(terminal, status: "running"), hook(otherTerminal, status: "needsInput")])
        let client = CmuxClient(settings: .init(), command: fixture.run)
        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, workspace)
        XCTAssertEqual(sessions[0].status, .blocked)
        await fixture.setHooks(try json(["sessions": [hook(terminal, status: "error"), hook(otherTerminal, status: "running")]]))
        let failed = try await client.listSessions()
        XCTAssertEqual(failed[0].status, .error)
        await fixture.setHooks(try json(["sessions": [hook(terminal, status: "idle")]]))
        let idle = try await client.listSessions()
        XCTAssertEqual(idle[0].status, .idle)
    }

    func testWorkspaceScopeIncludesAllTerminalAndBrowserTabsWithIndependentStatuses() async throws {
        let fixture = try makeFixture(hooks: [hook(terminal, status: "running"), hook(otherTerminal, status: "needsInput")])
        var settings = CmuxConnectionSettings()
        settings.scope = .workspace
        settings.workspaceID = workspace.uppercased()
        let client = CmuxClient(settings: settings, command: fixture.run)
        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.map(\.id), [terminal, otherTerminal, browser])
        XCTAssertEqual(sessions.map(\.status), [.working, .blocked, .unknown])
        XCTAssertEqual(sessions.map(\.environmentID), [workspace, workspace, workspace])
        let workspaces = try await client.workspaces()
        XCTAssertEqual(workspaces.map(\.id), [workspace])
    }

    func testAllWindowsAreListedAndWorkspaceSelectionUsesIDsDespiteDuplicateTitles() async throws {
        let fixture = try makeFixture()
        var second = treeWorkspace()
        second["id"] = otherWorkspace
        second["panes"] = []
        await fixture.setTree(try json(["windows": [
            ["id": window, "workspaces": [treeWorkspace()]],
            ["id": "10000000-0000-0000-0000-000000000002", "workspaces": [second]],
        ]]))
        var settings = CmuxConnectionSettings()
        settings.scope = .workspace
        settings.workspaceID = otherWorkspace
        let client = CmuxClient(settings: settings, command: fixture.run)
        let workspaces = try await client.workspaces()
        XCTAssertEqual(workspaces.map(\.id), [workspace, otherWorkspace])
        XCTAssertEqual(workspaces.map(\.title), ["Project", "Project"])
        let tabs = try await client.listSessions()
        XCTAssertTrue(tabs.isEmpty)
    }

    func testSelectionChangesAdvanceRecencyButRepeatedPollsDoNot() async throws {
        let fixture = try makeFixture()
        var settings = CmuxConnectionSettings()
        settings.scope = .workspace
        settings.workspaceID = workspace
        let client = CmuxClient(settings: settings, command: fixture.run)
        let first = try await client.listSessions()
        try await Task.sleep(nanoseconds: 5_000_000)
        let repeated = try await client.listSessions()
        XCTAssertEqual(first.map(\.updatedAt), repeated.map(\.updatedAt))
        await fixture.setTree(try json(["windows": [["id": window, "workspaces": [treeWorkspace(focusedSurface: otherTerminal)]]]]))
        let changed = try await client.listSessions()
        XCTAssertGreaterThan(changed[1].updatedAt, changed[0].updatedAt)
        XCTAssertEqual(changed[0].updatedAt, first[0].updatedAt)
    }

    func testMissingScopeSelectionDoesNotFallBackToAnotherWorkspace() async throws {
        let fixture = try makeFixture()
        var settings = CmuxConnectionSettings()
        settings.scope = .workspace
        let unselected = CmuxClient(settings: settings, command: fixture.run)
        do { _ = try await unselected.listSessions(); XCTFail("Missing selection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Choose a cmux workspace")) }
        settings.workspaceID = otherWorkspace
        let removed = CmuxClient(settings: settings, command: fixture.run)
        do { _ = try await removed.listSessions(); XCTFail("Closed workspace accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer open")) }
        let available = try await removed.workspaces()
        XCTAssertEqual(available.map(\.id), [workspace])
    }

    func testHistoricalInactiveAndDeadSurfaceRecordsNeverBecomeLiveAgents() async throws {
        var historical = hook(terminal, status: "error")
        historical["active_for_surface"] = false
        historical["updated_at_unix"] = 9999999999.0
        var wrongWorkspace = hook(otherTerminal, status: "error")
        wrongWorkspace["workspace_id"] = otherWorkspace
        let dead = hook("30000000-0000-0000-0000-000000000099", status: "running")
        let fixture = try makeFixture(hooks: [historical, wrongWorkspace, dead])
        let client = CmuxClient(settings: .init(), command: fixture.run)
        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.map(\.status), [.unknown])
    }

    func testNewestActiveAgentWinsWhenDifferentAgentStoresShareASurface() async throws {
        var old = hook(terminal, status: "error")
        old["session_id"] = "old-agent"
        old["updated_at_unix"] = 1.0
        let fixture = try makeFixture(hooks: [old, hook(terminal, status: "running")])
        let client = CmuxClient(settings: .init(), command: fixture.run)
        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.first?.status, .working)
    }

    func testOnlyMatchingUnreadCompletionMarksIdleAgentDone() async throws {
        let fixture = try makeFixture(hooks: [hook(terminal, status: "idle")], notices: [notice(subtitle: "Permission")])
        let client = CmuxClient(settings: .init(), command: fixture.run)
        try await assertStatus(client, .idle)
        await fixture.setNotifications(try json(["notifications": [notice(subtitle: "Completed")]]))
        let done = try await client.listSessions()
        XCTAssertEqual(done.first?.status, .done)
        XCTAssertEqual(done.first?.completionID, "40000000-0000-0000-0000-000000000001")
        var read = notice(subtitle: "Completed")
        read["is_read"] = true
        await fixture.setNotifications(try json(["notifications": [read]]))
        try await assertStatus(client, .idle)
        var stale = notice(subtitle: "Completed")
        stale["created_at"] = "2025-01-01T00:00:00Z"
        await fixture.setNotifications(try json(["notifications": [stale]]))
        try await assertStatus(client, .idle)
        var unrelated = notice(subtitle: "Completed")
        unrelated["title"] = "Build script"
        await fixture.setNotifications(try json(["notifications": [unrelated]]))
        try await assertStatus(client, .idle)
    }

    func testCompletionNeverOverridesInputErrorRunningOrMissingHooks() async throws {
        let fixture = try makeFixture(notices: [notice(subtitle: "Completed")])
        let client = CmuxClient(settings: .init(), command: fixture.run)
        try await assertStatus(client, .unknown)
        for (status, expected) in [("needsInput", SessionStatus.blocked), ("error", .error), ("running", .working)] {
            await fixture.setHooks(try json(["sessions": [hook(terminal, status: status)]]))
            try await assertStatus(client, expected)
        }
    }

    func testOpenWorkspaceTargetsAttentionSurfaceAndMarksOnlyThatSurfaceRead() async throws {
        let fixture = try makeFixture(hooks: [hook(terminal, status: "running"), hook(otherTerminal, status: "needsInput")])
        let client = CmuxClient(settings: .init(), command: fixture.run)
        let sessions = try await client.listSessions()
        let session = try XCTUnwrap(sessions.first)
        try await client.openSession(session)
        let mutations = try await fixture.mutations()
        XCTAssertEqual(mutations.map(\.0), ["window.focus", "workspace.select", "surface.focus", "notification.mark_read"])
        XCTAssertEqual(mutations[0].1["window_id"], window)
        XCTAssertEqual(mutations[1].1["workspace_id"], workspace)
        XCTAssertEqual(mutations[2].1["surface_id"], otherTerminal)
        XCTAssertEqual(mutations[3].1, ["workspace_id": workspace, "surface_id": otherTerminal])
    }

    func testInputUsesExactSurfaceAndPreservesLiteralTextWithoutSubmitting() async throws {
        let fixture = try makeFixture()
        var settings = CmuxConnectionSettings()
        settings.scope = .workspace
        settings.workspaceID = workspace
        settings.socketPath = "/tmp/cmux socket $(literal).sock"
        let client = CmuxClient(settings: settings, command: fixture.run)
        let sessions = try await client.listSessions()
        let session = try XCTUnwrap(sessions.first)
        let input = "literal \\n $(do-not-run) `unchanged`\nsecond line"
        try await client.sendInput(.text(input), to: session)
        let mutations = try await fixture.mutations()
        XCTAssertEqual(mutations.map(\.0), ["surface.send_text"])
        XCTAssertEqual(mutations[0].1["surface_id"], terminal)
        XCTAssertEqual(mutations[0].1["text"], input)
        XCTAssertNil(mutations[0].1["key"])
        let commands = await fixture.commands
        XCTAssertTrue(commands.filter { $0.contains("rpc") }.allSatisfy { Array($0.prefix(2)) == ["--socket", settings.socketPath] })
    }

    func testRemovedTargetAndBrowserInputFailWithoutSendingToAnotherTerminal() async throws {
        let fixture = try makeFixture()
        var settings = CmuxConnectionSettings()
        settings.scope = .workspace
        settings.workspaceID = workspace
        let client = CmuxClient(settings: settings, command: fixture.run)
        let sessions = try await client.listSessions()
        do { try await client.sendInput(.text("text"), to: sessions[2]); XCTFail("Browser accepted terminal input") }
        catch { XCTAssertTrue(error is SessionProviderError) }
        await fixture.setTree(try json(["windows": []]))
        do { try await client.openSession(sessions[0]); XCTFail("Removed target opened") }
        catch { XCTAssertTrue(error is SessionProviderError) }
        let mutations = try await fixture.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testMalformedAndDuplicateHierarchyFailInsteadOfProducingEmptySnapshot() async throws {
        let fixture = try makeFixture()
        let client = CmuxClient(settings: .init(), command: fixture.run)
        await fixture.setTree(Data("{}".utf8))
        do { _ = try await client.listSessions(); XCTFail("Malformed hierarchy accepted") }
        catch { XCTAssertTrue(error is CmuxError) }
        let workspaceNode = treeWorkspace()
        await fixture.setTree(try json(["windows": [["id": window, "workspaces": [workspaceNode, workspaceNode]]]]))
        do { _ = try await client.listSessions(); XCTFail("Duplicate workspace accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("workspace identity")) }
    }

    func testCLIProcessTimeoutAndCancellationAreBounded() async throws {
        var started = Date()
        do { _ = try await CmuxCommand.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.05); XCTFail("Timed out process succeeded") }
        catch { XCTAssertTrue(error is CmuxError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        started = Date()
        let task = Task { try await CmuxCommand.run(executable: "/bin/sleep", arguments: ["30"]) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled process succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testSocketRefusalIsActionable() async throws {
        do {
            _ = try await CmuxCommand.run(executable: "/bin/sh", arguments: ["-c", "echo 'ERROR: Access denied - only processes started inside cmux can connect' >&2; exit 1"])
            XCTFail("Refused socket succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Automation mode"))
        }
    }

    private func assertStatus(_ client: CmuxClient, _ expected: SessionStatus, file: StaticString = #filePath, line: UInt = #line) async throws {
        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.first?.status, expected, file: file, line: line)
    }

    private func makeFixture(hooks: [[String: Any]] = [], notices: [[String: Any]] = []) throws -> CmuxFixture {
        CmuxFixture(tree: try json(["windows": [["id": window, "workspaces": [treeWorkspace()]]]]),
                    hooks: try json(["sessions": hooks]), notifications: try json(["notifications": notices]))
    }

    private func treeWorkspace(focusedSurface: String? = nil) -> [String: Any] {
        let focused = focusedSurface ?? terminal
        return
        ["id": workspace, "title": "Project", "selected": true, "pinned": false,
         "panes": [["focused": true, "surfaces": [
            ["id": terminal, "title": "Agent", "type": "terminal", "focused": focused == terminal, "selected": focused == terminal],
            ["id": otherTerminal, "title": "Agent 2", "type": "terminal", "focused": focused == otherTerminal, "selected": focused == otherTerminal],
            ["id": browser, "title": "Preview", "type": "browser", "focused": focused == browser, "selected": focused == browser],
         ]]]]
    }

    private func hook(_ surface: String, status: String) -> [String: Any] {
        ["session_id": "agent-\(surface)", "workspace_id": workspace.uppercased(), "surface_id": surface.uppercased(),
         "agent_display_name": "Claude Code", "active_for_surface": true,
         "started_at": "2025-09-07T09:00:00Z", "updated_at_unix": 1757235600.0,
         "runtime_status": status, "agent_lifecycle": status, "cwd": "/work/project"]
    }

    private func notice(subtitle: String) -> [String: Any] {
        ["id": "40000000-0000-0000-0000-000000000001", "workspace_id": workspace,
         "surface_id": terminal, "is_read": false, "title": "Claude Code", "subtitle": subtitle,
         "created_at": "2025-09-07T09:00:01Z"]
    }

    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}

private actor CmuxFixture {
    private var tree: Data
    private var hooks: Data
    private var notifications: Data
    private var version = "cmux 0.64.22 (102) [ddd4a01bc]"
    private var capabilities = ["system.tree", "window.focus", "workspace.select", "surface.focus", "surface.send_text", "surface.send_key", "notification.list", "notification.mark_read", "agent.resolve_delivery_target", "surface.resume.get", "feed.list", "workspace.current", "workspace.next", "workspace.previous", "pane.list", "pane.focus"]
    private(set) var commands: [[String]] = []

    init(tree: Data, hooks: Data, notifications: Data) {
        self.tree = tree; self.hooks = hooks; self.notifications = notifications
    }

    func setVersion(_ value: String) { version = value }
    func setCapabilities(_ value: [String]) { capabilities = value }
    func setTree(_ data: Data) { tree = data }
    func setHooks(_ data: Data) { hooks = data }
    func setNotifications(_ data: Data) { notifications = data }

    func run(_ arguments: [String]) async throws -> Data {
        commands.append(arguments)
        if arguments == ["--version"] { return Data(version.utf8) }
        if arguments.first == "sessions" { return hooks }
        guard let rpc = arguments.firstIndex(of: "rpc") else { throw CmuxError.badResponse("fixture command") }
        switch arguments[rpc + 1] {
        case "system.capabilities": return try JSONSerialization.data(withJSONObject: ["methods": capabilities])
        case "system.tree": return tree
        case "feed.list": return try JSONSerialization.data(withJSONObject: ["items": []])
        case "notification.list": return notifications
        default: return Data("{}".utf8)
        }
    }

    func mutations() throws -> [(String, [String: String])] {
        try commands.compactMap { arguments in
            guard let rpc = arguments.firstIndex(of: "rpc") else { return nil }
            let method = arguments[rpc + 1]
            guard !["system.capabilities", "system.tree", "notification.list", "feed.list"].contains(method) else { return nil }
            let params = try JSONSerialization.jsonObject(with: Data(arguments[rpc + 2].utf8)) as? [String: String] ?? [:]
            return (method, params)
        }
    }
}
