import Foundation
@testable import WLKit

@main struct VerifyCmux {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let workspaces = try await CmuxClient(settings: .init()).workspaces()
            print("cmux ≥ \(CmuxClient.minimumVersion): \(workspaces.count) live workspaces")
            for workspace in workspaces { print("\(workspace.id)  \(workspace.status.title)  \(workspace.title)") }
            return
        }
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await navigation(fixture)
        try await completedTurns(fixture)
        try await codexLiveBinding(fixture)
        for version in ["cmux 0.64.22 (102)", "cmux 0.65.0", "cmux 1.0.0"] {
            try CmuxClient.requireSupportedVersion(version)
        }
        for version in ["cmux 0.62.2", "cmux 0.64.21", "cmux nightly"] {
            do { try CmuxClient.requireSupportedVersion(version); fatalError("Accepted old cmux") }
            catch { expect(error.localizedDescription.contains("0.64.22"), "Update requirement") }
        }
        var settings = fixture.settings
        let client = CmuxClient(settings: settings)
        expect(try await client.listSessions().map(\.status) == [.unknown], "No hooks means unknown")
        fixture.hooks = [fixture.hook(fixture.firstSurface, status: "running"), fixture.hook(fixture.secondSurface, status: "needsInput")]
        try fixture.write()
        let workspaces = try await client.listSessions()
        expect(workspaces.map(\.status) == [.blocked], "Workspace aggregates both agents")
        expect(workspaces[0].id == fixture.workspace, "Workspace IDs round-trip through selector")
        try await client.openSession(workspaces[0])
        let focus = try fixture.mutations()
        expect(focus.map(\.0) == ["window.focus", "workspace.select", "surface.focus", "notification.mark_read"], "Exact focus order")
        expect(focus[2].1["surface_id"] == fixture.secondSurface, "Attention surface selected")
        expect(focus[3].1 == ["workspace_id": fixture.workspace, "surface_id": fixture.secondSurface], "Only selected surface acknowledged")
        settings.scope = .workspace
        settings.workspaceID = fixture.workspace
        let scoped = CmuxClient(settings: settings)
        let tabs = try await scoped.listSessions()
        expect(tabs.map(\.status) == [.working, .blocked, .unknown], "Terminal and browser tabs keep separate statuses")
        expect(try await scoped.workspaces().map(\.id) == [fixture.workspace], "Selector independent of scope")
        let recency = tabs.map(\.updatedAt)
        expect(try await scoped.listSessions().map(\.updatedAt) == recency, "Polling does not advance recency")
        fixture.focusedSurface = fixture.secondSurface
        try fixture.write()
        let changed = try await scoped.listSessions()
        expect(changed[1].updatedAt > changed[0].updatedAt, "Observed selection advances recency")
        let literal = "literal \\n $(never-run) `unchanged`\nsecond line"
        try await scoped.sendInput(.text(literal), to: tabs[0])
        let input = try fixture.mutations().last!
        expect(input.0 == "surface.send_text" && input.1["text"] == literal && input.1["surface_id"] == fixture.firstSurface, "Literal text without auto-submit")
        do { try await scoped.sendInput(.text("text"), to: tabs[2]); fatalError("Browser accepted terminal input") }
        catch { expect(error is SessionProviderError, "Browser rejected") }
        fixture.hooks = [fixture.hook(fixture.firstSurface, status: "idle")]
        fixture.notices = [fixture.notice("Permission")]
        try fixture.write()
        expect(try await client.listSessions().first?.status == .idle, "Arbitrary unread is not done")
        fixture.notices = [fixture.notice("Completed")]
        try fixture.write()
        expect(try await client.listSessions().first?.status == .done, "Unread matching completion is done")
        fixture.notices[0]["is_read"] = true
        try fixture.write()
        expect(try await client.listSessions().first?.status == .idle, "Native read clears done")
        fixture.hooks = [fixture.hook(fixture.firstSurface, status: "error", active: false), fixture.hook(UUID().uuidString, status: "running")]
        try fixture.write()
        expect(try await client.listSessions().first?.status == .unknown, "Historical and dead surface records ignored")
        settings.workspaceID = UUID().uuidString
        let missing = CmuxClient(settings: settings)
        do { _ = try await missing.listSessions(); fatalError("Missing workspace silently remapped") }
        catch { expect(error.localizedDescription.contains("no longer open"), "Missing workspace is actionable") }
        fixture.version = "cmux 0.62.2"
        try fixture.write()
        do { _ = try await CmuxClient(settings: fixture.settings).listSessions(); fatalError("Old CLI accepted") }
        catch { expect(error.localizedDescription.contains("Update cmux"), "Old CLI rejected") }
        fixture.version = "cmux 0.64.22"
        fixture.methods = []
        try fixture.write()
        do { _ = try await CmuxClient(settings: fixture.settings).listSessions(); fatalError("Old server accepted") }
        catch { expect(error.localizedDescription.contains("restart it"), "Old server rejected") }
        fixture.refuse = true
        try fixture.write()
        do { _ = try await CmuxClient(settings: fixture.settings).listSessions(); fatalError("Refused socket accepted") }
        catch { expect(error.localizedDescription.contains("Automation mode"), "Socket refusal is actionable") }
        let start = Date()
        do { _ = try await CmuxCommand.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.05); fatalError("Timeout failed") }
        catch { expect(error is CmuxError, "Timeout error") }
        let task = Task { try await CmuxCommand.run(executable: "/bin/sleep", arguments: ["30"]) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; fatalError("Cancellation failed") }
        catch { expect(error is CancellationError, "Cancellation error") }
        expect(Date().timeIntervalSince(start) < 2, "Timeout and cancellation are bounded")
        print("cmux verification passed: version/server gates, workspace/tab scopes, multi-agent status, native reads, exact focus/input, recency, stale records, timeout and cancellation")
    }

    @MainActor private static func navigation(_ fixture: Fixture) async throws {
        let client = CmuxClient(settings: fixture.settings)
        fixture.responses["workspace.current"] = ["workspace_id": fixture.workspace]
        fixture.responses["pane.list"] = ["panes": [
            ["id": "left", "focused": false, "selected_surface_id": fixture.firstSurface, "pixel_frame": ["x": 0, "y": 0, "width": 100, "height": 100]],
            ["id": "right", "focused": true, "selected_surface_id": fixture.secondSurface, "pixel_frame": ["x": 100, "y": 0, "width": 100, "height": 100]],
            ["id": "below", "focused": false, "pixel_frame": ["x": 0, "y": 100, "width": 200, "height": 100]],
        ]]
        try fixture.write()
        try await client.performControl(.nextTab)
        expect(try fixture.mutations().first?.1["surface_id"] == fixture.secondSurface, "Dial next follows tab order in the current pane")
        try await client.performControl(.previousTab)
        expect(try fixture.mutations().suffix(2).first?.1["surface_id"] == "30000000-0000-0000-0000-000000000003", "Dial previous wraps and includes browser tabs")
        try await client.performControl(.focusLeft)
        expect(try fixture.mutations().suffix(2).first?.1["pane_id"] == "left", "Joystick left chooses the neighboring pane")
        try await client.performControl(.focusDown)
        expect(try fixture.mutations().last?.1["pane_id"] == "below", "Joystick down uses cmux pane geometry")
        try await client.performControl(.nextWorkspace)
        expect(try fixture.mutations().last?.0 == "workspace.next", "Workspace navigation uses the native operation")
        let literal = "Keep $(literal) `literal` and a new\nline"
        try await client.performControl(.insertText, text: literal)
        expect(try fixture.mutations().last?.1["text"] == literal, "Macro text arrives verbatim without Enter")
        try await client.performControl(.submit)
        expect(try fixture.mutations().last?.1["key"] == "enter", "Submit is a separate explicit action")
        try await client.executeCommand("Previous workspace.")
        expect(try fixture.mutations().last?.0 == "workspace.previous", "Dictated commands tolerate capitalization and sentence punctuation")
        try await client.executeCommand("open Project")
        expect(try fixture.mutations().contains { $0.0 == "workspace.select" && $0.1["workspace_id"] == fixture.workspace }, "Spoken workspace names resolve to exact IDs")
        fixture.focusedSurface = "30000000-0000-0000-0000-000000000003"
        try fixture.write()
        do { try await client.performControl(.submit); fatalError("Control sent Enter to a browser") }
        catch SessionProviderError.unsupportedInput {}
        fixture.focusedSurface = fixture.firstSurface
        try fixture.write()
        let before = try fixture.mutations().count
        do { try await client.executeCommand("open terminal"); fatalError("Ambiguous terminal name accepted") }
        catch ConfigurationError.invalid {}
        do { try await client.executeCommand("run rm -rf something"); fatalError("Arbitrary command accepted") }
        catch ConfigurationError.invalid {}
        expect(try fixture.mutations().count == before, "Unknown or ambiguous voice commands cannot send terminal input")
        fixture.responses = [:]
        try fixture.write()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("calls.jsonl"))
        print("Dial/tab/workspace navigation, directional panes, explicit input and voice command routing passed.")
    }

    @MainActor private static func completedTurns(_ fixture: Fixture) async throws {
        var settings = fixture.settings
        settings.scope = .workspace; settings.workspaceID = fixture.workspace
        let client = CmuxClient(settings: settings)
        var codex = fixture.hook(fixture.firstSurface, status: "running")
        codex["agent"] = "codex"; codex["agent_display_name"] = "Codex"
        codex["active_prompt_turn_id"] = "abandoned-turn"
        codex["last_prompt_turn_id"] = "completed-turn"
        var claude = fixture.hook(fixture.secondSurface, status: "needsInput")
        claude["agent"] = "claude"
        claude["updated_at_unix"] = 1757235661.0
        let stop = fixture.event(codex, kind: "stop", second: 1)
        let claudeStop = fixture.event(claude, kind: "stop", second: 1)
        fixture.hooks = [codex, claude]
        fixture.feed = [stop, claudeStop]
        var waiting = fixture.notice("Waiting")
        waiting["surface_id"] = fixture.secondSurface; waiting["is_read"] = true
        waiting["created_at"] = "2025-09-07T09:01:01Z"
        fixture.notices = [waiting]; try fixture.write()
        expect(try await client.listSessions().map(\.status) == [.idle, .idle, .unknown], "Completed Codex and Claude must stop running or requesting input")
        var completion = fixture.notice("")
        completion["title"] = "Project"; fixture.notices.append(completion); try fixture.write()
        expect(try await client.listSessions().first?.status == .done, "A stop event corroborates completion even with customized notification titles")
        fixture.feed.append(fixture.event(codex, kind: "userPrompt", second: 2)); try fixture.write()
        expect(try await client.listSessions().first?.status == .working, "A new prompt supersedes the old completion")
        fixture.feed.append(fixture.event(codex, kind: "permissionRequest", second: 3, status: "pending")); try fixture.write()
        expect(try await client.listSessions().first?.status == .blocked, "Actual pending approval remains blocked")
        fixture.feed[3]["status"] = "resolved"; try fixture.write()
        expect(try await client.listSessions().first?.status == .working, "Resolved approval resumes the active turn")
        waiting["subtitle"] = "Permission"; fixture.notices = [waiting]; try fixture.write()
        expect(try await client.listSessions()[1].status == .blocked, "A real Claude permission notification is not an idle reminder")
        fixture.notices = []; fixture.feed = [fixture.event(codex, kind: "toolResult", second: 4)]; try fixture.write()
        expect(try await client.listSessions().first?.status == .working, "Subagent completion cannot finish its parent")
        fixture.feed = [stop]; fixture.feed[0]["workstream_id"] = "codex-another-session"; try fixture.write()
        expect(try await client.listSessions().first?.status == .working, "Unrelated session stops are ignored")
        fixture.feed = [stop]; fixture.hooks[0]["updated_at_unix"] = 1757235610.0; try fixture.write()
        expect(try await client.listSessions().first?.status == .working, "A newer hook must not be overwritten by a stale feed stop")
        fixture.hooks = []; fixture.feed = []; fixture.notices = []; try fixture.write()
        print("Completed-turn, idle reminder, real approval, new prompt and stale-feed regressions passed.")
    }

    @MainActor private static func codexLiveBinding(_ fixture: Fixture) async throws {
        var settings = fixture.settings
        settings.scope = .workspace; settings.workspaceID = fixture.workspace
        let client = CmuxClient(settings: settings)
        var record = fixture.hook(fixture.firstSurface, status: "running", active: false)
        record["agent"] = "codex"; record["agent_display_name"] = "Codex"
        record["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        let checkpoint = record["session_id"] as! String
        let delivery: [String: Any] = ["source": "pid", "pid_resolution": "corroborated", "workspace_id": fixture.workspace, "surface_id": fixture.firstSurface]
        let resume: [String: Any] = ["workspace_id": fixture.workspace, "surface_id": fixture.firstSurface, "cleared": false,
                                     "resume_binding": ["kind": "codex", "checkpoint_id": checkpoint]]
        fixture.responses = ["agent.resolve_delivery_target": delivery, "surface.resume.get": resume]
        for (status, expected) in [("running", SessionStatus.working), ("needsInput", .blocked), ("idle", .idle), ("error", .error)] {
            record["runtime_status"] = status; record["agent_lifecycle"] = status
            fixture.hooks = [record]; try fixture.write()
            expect(try await client.listSessions().first?.status == expected, "Codex \(status) must work without Claude's active-session index")
        }
        record["runtime_status"] = "idle"; record["agent_lifecycle"] = "idle"
        fixture.hooks = [record]
        var notice = fixture.notice("Completed"); notice["title"] = "Codex"
        fixture.notices = [notice]; try fixture.write()
        expect(try await client.listSessions().first?.status == .done, "Verified Codex retains native completion status")
        fixture.notices = []
        record["runtime_status"] = "running"; record["agent_lifecycle"] = "running"
        record["workspace_id"] = UUID().uuidString
        var movedDelivery = delivery; movedDelivery["surface_id"] = fixture.secondSurface
        var movedResume = resume; movedResume["surface_id"] = fixture.secondSurface
        fixture.responses = ["agent.resolve_delivery_target": movedDelivery, "surface.resume.get": movedResume]
        var historical = record; historical["session_id"] = "superseded-codex"; historical["runtime_status"] = "error"; historical["updated_at_unix"] = 9999999999.0
        fixture.hooks = [historical, record]; try fixture.write()
        let moved = try await client.listSessions()
        expect(moved.map(\.status) == [.unknown, .working, .unknown], "Live PID and checkpoint override obsolete terminal IDs and superseded records")
        try await client.openSession(moved[1])
        expect(try fixture.mutations().contains { $0.0 == "surface.focus" && $0.1["surface_id"] == fixture.secondSurface }, "Codex focus uses its verified current terminal")
        let validResponses = fixture.responses
        for rejection in ["checkpoint", "cleared", "identity", "source", "closed", "unavailable"] {
            fixture.responses = validResponses
            switch rejection {
            case "checkpoint": fixture.responses["surface.resume.get"]?["resume_binding"] = ["kind": "codex", "checkpoint_id": "another-conversation"]
            case "cleared": fixture.responses["surface.resume.get"]?["cleared"] = true
            case "identity": fixture.responses["surface.resume.get"]?["workspace_id"] = UUID().uuidString
            case "source": fixture.responses["agent.resolve_delivery_target"]?["source"] = "focused"
            case "closed": fixture.responses["agent.resolve_delivery_target"]?["surface_id"] = UUID().uuidString
            default: fixture.responses["agent.resolve_delivery_target"] = [:]
            }
            try fixture.write()
            expect(try await client.listSessions().allSatisfy { $0.status == .unknown }, "Unproven Codex \(rejection) must remain unknown")
        }
        fixture.responses = validResponses
        record["pid"] = Int(Int32.max); fixture.hooks = [record]; try fixture.write()
        expect(try await client.listSessions().allSatisfy { $0.status == .unknown }, "A dead Codex PID must not revive a historical session")
        record["pid"] = Int(ProcessInfo.processInfo.processIdentifier); record["agent_lifecycle"] = "ended"
        fixture.hooks = [record]; try fixture.write()
        expect(try await client.listSessions().allSatisfy { $0.status == .unknown }, "An ended Codex lifecycle must not reuse a live parent PID")
        fixture.hooks = []; fixture.notices = []; fixture.responses = [:]
        try fixture.write()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("calls.jsonl"))
        print("Codex live process/checkpoint binding, restored terminal IDs, lifecycle status and stale-record rejection passed.")
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
}

private final class Fixture {
    let directory: URL
    let window = "10000000-0000-0000-0000-000000000001"
    let workspace = "20000000-0000-0000-0000-000000000001"
    let firstSurface = "30000000-0000-0000-0000-000000000001"
    let secondSurface = "30000000-0000-0000-0000-000000000002"
    var focusedSurface = "30000000-0000-0000-0000-000000000001"
    var version = "cmux 0.64.22 (102)"
    var hooks: [[String: Any]] = []
    var notices: [[String: Any]] = []
    var feed: [[String: Any]] = []
    var refuse = false
    var responses: [String: [String: Any]] = [:]
    var methods = ["system.tree", "window.focus", "workspace.select", "surface.focus", "surface.send_text", "surface.send_key", "notification.list", "notification.mark_read", "agent.resolve_delivery_target", "surface.resume.get", "feed.list", "workspace.current", "workspace.next", "workspace.previous", "pane.list", "pane.focus"]
    var settings: CmuxConnectionSettings {
        var settings = CmuxConnectionSettings()
        settings.cliPath = directory.appendingPathComponent("cmux fixture").path
        settings.socketPath = "/tmp/cmux socket $(literal).sock"
        return settings
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("micro-cmux-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let cli = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        root = pathlib.Path(__file__).parent
        state = json.loads((root / 'state.json').read_text())
        args = sys.argv[1:]
        with (root / 'calls.jsonl').open('a') as f:
            f.write(json.dumps(args) + '\\n')
        if args == ['--version']:
            print(state['version'])
        elif args[0] == 'sessions':
            print(json.dumps({'sessions': state['hooks']}))
        elif state['refuse']:
            sys.stderr.write('ERROR: Access denied - only processes started inside cmux can connect')
            sys.exit(1)
        else:
            method = args[args.index('rpc') + 1]
            print(json.dumps({'system.capabilities': {'methods': state['methods']}, 'system.tree': state['tree'], 'notification.list': {'notifications': state['notices']}, 'feed.list': {'items': state['feed']}, **state['responses']}.get(method, {})))
        """
        try Data(cli.utf8).write(to: URL(fileURLWithPath: settings.cliPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: settings.cliPath)
        try write()
    }

    func write() throws {
        let surfaces: [[String: Any]] = [(firstSurface, "terminal"), (secondSurface, "terminal"), ("30000000-0000-0000-0000-000000000003", "browser")].map { id, type in
            ["id": id, "title": type, "type": type, "focused": id == focusedSurface, "selected": id == focusedSurface]
        }
        let tree: [String: Any] = ["windows": [["id": window, "workspaces": [["id": workspace, "title": "Project", "selected": true, "pinned": false, "panes": [["focused": true, "surfaces": surfaces]]]]]]]
        let state: [String: Any] = ["version": version, "methods": methods, "tree": tree, "hooks": hooks, "notices": notices, "feed": feed, "refuse": refuse, "responses": responses]
        try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    func hook(_ surface: String, status: String, active: Bool = true) -> [String: Any] {
        ["session_id": "agent-\(surface)", "workspace_id": workspace, "surface_id": surface, "agent_display_name": "Claude Code", "active_for_surface": active,
         "started_at": "2025-09-07T09:00:00Z", "updated_at_unix": 1757235600.0, "runtime_status": status, "agent_lifecycle": status]
    }

    func event(_ hook: [String: Any], kind: String, second: Int, status: String = "telemetry") -> [String: Any] {
        ["id": UUID().uuidString, "workstream_id": "\(hook["agent"]!)-\(hook["session_id"]!)",
         "source": hook["agent"]!, "kind": kind, "status": status,
         "created_at": String(format: "2025-09-07T09:00:%02dZ", second), "updated_at": String(format: "2025-09-07T09:00:%02dZ", second)]
    }

    func notice(_ subtitle: String) -> [String: Any] {
        ["id": "40000000-0000-0000-0000-000000000001", "workspace_id": workspace, "surface_id": firstSurface, "is_read": false,
         "title": "Claude Code", "subtitle": subtitle, "created_at": "2025-09-07T09:00:01Z"]
    }

    func mutations() throws -> [(String, [String: String])] {
        let lines = try String(contentsOf: directory.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n")
        return try lines.compactMap { line in
            let arguments = try JSONDecoder().decode([String].self, from: Data(line.utf8))
            guard let index = arguments.firstIndex(of: "rpc") else { return nil }
            let method = arguments[index + 1]
            guard !["system.capabilities", "system.tree", "notification.list", "agent.resolve_delivery_target", "surface.resume.get", "feed.list", "workspace.current", "pane.list"].contains(method) else { return nil }
            return (method, try JSONDecoder().decode([String: String].self, from: Data(arguments[index + 2].utf8)))
        }
    }
}
