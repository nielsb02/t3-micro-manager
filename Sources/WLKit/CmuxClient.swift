import Foundation

public enum CmuxError: LocalizedError {
    case missingCLI(String), unsupportedVersion(String), badResponse(String)
    case commandFailed(String), incompatibleServer, timeout, chooseWorkspace, missingWorkspace

    public var errorDescription: String? {
        switch self {
        case .missingCLI(let path):
            return "cmux could not be started at \(path). Install cmux 0.64.22 or newer, or choose its bundled CLI."
        case .unsupportedVersion(let version):
            return "cmux \(version) is unsupported. Update cmux to 0.64.22 or newer and restart it."
        case .badResponse(let operation):
            return "cmux returned an unsupported response for \(operation). Update and restart cmux."
        case .commandFailed(let detail):
            let lower = detail.lowercased()
            if lower.contains("access denied") || lower.contains("authentication") || lower.contains("password") {
                return "Allow Micro Manager to connect in cmux Settings → Socket Control → Automation mode. Password mode also works with the cmux CLI's saved credential. \(detail)"
            }
            return "Could not communicate with cmux. Open cmux and check Settings → Socket Control and the configured socket path. \(detail)"
        case .timeout:
            return "cmux did not respond within 8 seconds. Check that cmux is running and Socket Control allows Automation mode."
        case .incompatibleServer:
            return "The running cmux app lacks the required integration APIs. Update cmux to 0.64.22 or newer, restart it, and check the socket path."
        case .chooseWorkspace:
            return "Choose a cmux workspace to show its terminal and browser tabs."
        case .missingWorkspace:
            return "The selected cmux workspace is no longer open. Choose another workspace or switch to Workspaces."
        }
    }
}

@MainActor public final class CmuxClient {
    public static let minimumVersion = "0.64.22"
    public static let inputCapabilities = SessionInputCapabilities(acceptsText: true, actions: [
        SessionAction(id: "submit", title: "Submit"),
        SessionAction(id: "escape", title: "Escape"),
        SessionAction(id: "interrupt", title: "Interrupt"),
    ])

    typealias Command = @Sendable ([String]) async throws -> Data
    private let settings: CmuxConnectionSettings
    private let command: Command
    private var versionChecked = false
    private var lastSelection: Set<String> = []
    private var selectedAt: [String: String] = [:]
    private var latest: [Workspace] = []

    public convenience init(settings: CmuxConnectionSettings) {
        self.init(settings: settings) { arguments in
            try await CmuxCommand.run(executable: settings.cliPath, arguments: arguments)
        }
    }

    init(settings: CmuxConnectionSettings, command: @escaping Command) {
        self.settings = settings
        self.command = command
    }

    public func listSessions() async throws -> [AgentSession] {
        try await refresh()
        switch settings.scope {
        case .workspaces: return latest.map(\.session)
        case .workspace:
            guard !settings.workspaceID.isEmpty else { throw CmuxError.chooseWorkspace }
            guard let workspace = latest.first(where: { $0.id == settings.workspaceID.lowercased() }) else {
                throw CmuxError.missingWorkspace
            }
            return workspace.surfaces.map(\.session)
        }
    }

    public func workspaces() async throws -> [AgentSession] {
        try await refresh()
        return latest.map(\.session)
    }

    public func openSession(_ session: AgentSession) async throws {
        try await refresh()
        let (workspace, surface) = try target(for: session, preferAttention: true)
        _ = try await rpc("window.focus", params: ["window_id": workspace.windowID])
        let params = ["window_id": workspace.windowID, "workspace_id": workspace.id]
        _ = try await rpc("workspace.select", params: params)
        if let surface {
            _ = try await rpc("surface.focus", params: params.merging(["surface_id": surface.id]) { _, new in new })
            _ = try await rpc("notification.mark_read", params: ["workspace_id": workspace.id, "surface_id": surface.id])
        }
    }

    public func sendInput(_ input: SessionInput, to session: AgentSession) async throws {
        guard Self.inputCapabilities.supports(input) else { throw SessionProviderError.unsupportedInput }
        try await refresh()
        let (workspace, surface) = try target(for: session, preferAttention: false)
        guard let surface, surface.kind == "terminal" else { throw SessionProviderError.unsupportedInput }
        var params = ["window_id": workspace.windowID, "workspace_id": workspace.id, "surface_id": surface.id]
        switch input {
        case .text(let text):
            params["text"] = text
            _ = try await rpc("surface.send_text", params: params)
        case .action(let id):
            let keys = ["submit": "enter", "escape": "escape", "interrupt": "ctrl+c"]
            guard let key = keys[id] else { throw SessionProviderError.unsupportedInput }
            params["key"] = key
            _ = try await rpc("surface.send_key", params: params)
        }
    }

    public func performControl(_ action: SessionControlAction, text: String = "") async throws {
        try Task.checkCancellation()
        try await checkCompatibility()
        if action == .nextAttention {
            try await refresh()
            let surfaces = latest.flatMap(\.surfaces)
            let candidates = [SessionStatus.error, .blocked, .done].flatMap { status in
                surfaces.filter { $0.session.status == status }.map(\.session)
            }
            if !candidates.isEmpty {
                let focused = surfaces.first(where: \.focused)?.id
                let next = candidates.firstIndex(where: { $0.id == focused }).map { ($0 + 1) % candidates.count } ?? 0
                try await openSession(candidates[next])
            }
            return
        }
        let tree: Tree = try decode(await rpc("system.tree", params: ["all_windows": true]), operation: "system.tree")
        let current: CurrentWorkspace = try decode(await rpc("workspace.current"), operation: "workspace.current")
        guard let window = tree.windows.first(where: { $0.workspaces.contains { $0.id.lowercased() == current.workspaceId.lowercased() } }),
              let workspace = window.workspaces.first(where: { $0.id.lowercased() == current.workspaceId.lowercased() }),
              let pane = workspace.panes.first(where: \.focused) else { throw SessionProviderError.unavailableSession }
        let params = ["window_id": window.id, "workspace_id": workspace.id]
        switch action {
        case .nextWorkspace, .previousWorkspace:
            _ = try await rpc(action == .nextWorkspace ? "workspace.next" : "workspace.previous", params: ["window_id": window.id])
        case .nextTab, .previousTab:
            let surfaces = pane.surfaces.filter { $0.type == "terminal" || $0.type == "browser" }
            guard !surfaces.isEmpty, let index = surfaces.firstIndex(where: { $0.selected || $0.focused }) else { return }
            let next = (index + (action == .nextTab ? 1 : surfaces.count - 1)) % surfaces.count
            _ = try await rpc("surface.focus", params: params.merging(["surface_id": surfaces[next].id]) { _, new in new })
            _ = try await rpc("notification.mark_read", params: ["workspace_id": workspace.id, "surface_id": surfaces[next].id])
        case .focusLeft, .focusRight, .focusUp, .focusDown:
            let panes: PaneLayout = try decode(await rpc("pane.list", params: params), operation: "pane.list")
            guard let origin = panes.panes.first(where: \.focused), let frame = origin.pixelFrame else { return }
            let target = panes.panes.filter { $0.id != origin.id }.compactMap { candidate -> (LayoutPane, Double)? in
                guard let next = candidate.pixelFrame else { return nil }
                let dx = next.x + next.width / 2 - frame.x - frame.width / 2
                let dy = next.y + next.height / 2 - frame.y - frame.height / 2
                let primary = action == .focusLeft ? -dx : action == .focusRight ? dx : action == .focusUp ? -dy : dy
                let perpendicular = [.focusLeft, .focusRight].contains(action) ? abs(dy) : abs(dx)
                guard primary > 1 else { return nil }
                return (candidate, primary + perpendicular * 2)
            }.min { $0.1 < $1.1 }?.0
            if let target {
                _ = try await rpc("pane.focus", params: params.merging(["pane_id": target.id]) { _, new in new })
                if let surface = target.selectedSurfaceId {
                    _ = try await rpc("notification.mark_read", params: ["workspace_id": workspace.id, "surface_id": surface])
                }
            }
        case .submit, .escape, .interrupt, .insertText:
            guard let surface = pane.surfaces.first(where: { $0.selected || $0.focused }), surface.type == "terminal" else {
                throw SessionProviderError.unsupportedInput
            }
            var destination = params.merging(["surface_id": surface.id]) { _, new in new }
            if action == .insertText {
                destination["text"] = text
                _ = try await rpc("surface.send_text", params: destination)
            } else {
                destination["key"] = action == .submit ? "enter" : action == .escape ? "escape" : "ctrl+c"
                _ = try await rpc("surface.send_key", params: destination)
            }
        default: throw SessionProviderError.unsupportedInput
        }
    }

    public func executeCommand(_ text: String) async throws {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands: [String: SessionControlAction] = [
            "next terminal": .nextTab, "previous terminal": .previousTab,
            "next tab": .nextTab, "previous tab": .previousTab,
            "next workspace": .nextWorkspace, "previous workspace": .previousWorkspace,
            "left": .focusLeft, "right": .focusRight, "up": .focusUp, "down": .focusDown,
            "attention": .nextAttention, "submit": .submit, "escape": .escape, "interrupt": .interrupt,
        ]
        if let action = commands[input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))] {
            try await performControl(action); return
        }
        if input.lowercased().hasPrefix("open ") {
            let name = String(input.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            try await refresh()
            let choices = latest.map(\.session) + latest.flatMap(\.surfaces).map(\.session)
            let matches = choices.filter { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
            guard matches.count == 1, let match = matches.first else {
                throw ConfigurationError.invalid(matches.isEmpty ? "No open workspace or tab is named ‘\(name)’." : "More than one workspace or tab is named ‘\(name)’. Rename it in cmux to make the command unique.")
            }
            try await openSession(match); return
        }
        throw ConfigurationError.invalid("Use next/previous workspace, next/previous terminal, left/right/up/down, attention, or open followed by an exact workspace or tab name.")
    }

    private func target(for session: AgentSession, preferAttention: Bool) throws -> (Workspace, Surface?) {
        if let workspace = latest.first(where: { $0.session.id == session.id }) {
            let attention: [SessionStatus] = [.error, .blocked, .done]
            let surface = preferAttention ? attention.lazy.compactMap { status in
                workspace.surfaces.first { $0.session.status == status }
            }.first : nil
            return (workspace, surface ?? workspace.surfaces.first(where: \.focused)
                    ?? workspace.surfaces.first(where: \.selected) ?? workspace.surfaces.first)
        }
        for workspace in latest {
            if let surface = workspace.surfaces.first(where: { $0.session.id == session.id }) {
                return (workspace, surface)
            }
        }
        throw SessionProviderError.unavailableSession
    }

    private func checkCompatibility() async throws {
        if !versionChecked {
            let version = try await command(["--version"])
            try Self.requireSupportedVersion(String(decoding: version, as: UTF8.self))
            let capabilities: Capabilities = try decode(await rpc("system.capabilities"), operation: "system.capabilities")
            let required: Set<String> = ["system.tree", "window.focus", "workspace.select", "surface.focus",
                                         "surface.send_text", "surface.send_key", "notification.list", "notification.mark_read",
                                         "agent.resolve_delivery_target", "surface.resume.get", "feed.list", "workspace.current", "workspace.next", "workspace.previous", "pane.list", "pane.focus"]
            guard required.isSubset(of: Set(capabilities.methods)) else { throw CmuxError.incompatibleServer }
            versionChecked = true
        }
    }

    private func refresh() async throws {
        try Task.checkCancellation()
        try await checkCompatibility()
        async let treeData = rpc("system.tree", params: ["all_windows": true])
        async let hookData = command(["sessions", "list", "--json", "--all"])
        async let notificationData = rpc("notification.list")
        async let feedData = rpc("feed.list")
        let (tree, hooks, notifications, feed) = try await (treeData, hookData, notificationData, feedData)
        try Task.checkCancellation()
        let hierarchy: Tree = try decode(tree, operation: "system.tree")
        let agents: HookList = try decode(hooks, operation: "sessions list")
        let notices: NotificationList = try decode(notifications, operation: "notification.list")
        let activity: ActivityFeed = try decode(feed, operation: "feed.list")
        let activeAgents = try await resolveActiveAgents(agents.sessions, in: hierarchy)
        try Task.checkCancellation()
        latest = try snapshot(hierarchy: hierarchy, activeAgents: activeAgents, notices: notices, feed: activity)
    }

    private func rpc(_ method: String, params: [String: Any] = [:]) async throws -> Data {
        let encoded = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        var arguments: [String] = []
        if !settings.socketPath.isEmpty { arguments += ["--socket", settings.socketPath] }
        arguments += ["rpc", method, String(decoding: encoded, as: UTF8.self)]
        return try await command(arguments)
    }

    nonisolated static func requireSupportedVersion(_ output: String) throws {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        guard parts.count >= 2, parts[0] == "cmux" else { throw CmuxError.unsupportedVersion(trimmed) }
        let version = String(parts[1])
        let numbers = version.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3, version.split(separator: ".").count == 3,
              !numbers.lexicographicallyPrecedes([0, 64, 22]) else {
            throw CmuxError.unsupportedVersion(version)
        }
    }

    private func resolveActiveAgents(_ hooks: [HookSession], in hierarchy: Tree) async throws -> [String: HookSession] {
        var owners: [String: (workspaceID: String, kind: String)] = [:]
        for window in hierarchy.windows {
            for workspace in window.workspaces {
                for surface in workspace.panes.flatMap(\.surfaces) {
                    owners[surface.id.lowercased()] = (workspace.id.lowercased(), surface.type)
                }
            }
        }
        let indexed = hooks.filter { $0.activeForSurface && owners[$0.surfaceId.lowercased()]?.workspaceID == $0.workspaceId.lowercased() }
        var active = Dictionary(indexed.map { ($0.surfaceId.lowercased(), $0) },
                                uniquingKeysWith: { $0.updatedAtUnix >= $1.updatedAtUnix ? $0 : $1 })
        // cmux 0.64.22's Codex handlers do not populate the active-session index.
        // Resolve live ownership and its exact checkpoint before using an unindexed record.
        let candidates = hooks.filter {
            guard !$0.activeForSurface, $0.agent == "codex", $0.agentLifecycle != "ended", $0.status != .unknown,
                  let pid = $0.pid, pid > 0, pid <= Int(Int32.max) else { return false }
            return kill(Int32(pid), 0) == 0
        }
        for (pid, records) in Dictionary(grouping: candidates, by: { $0.pid! }) {
            try Task.checkCancellation()
            do {
                let target: DeliveryTarget = try decode(await rpc("agent.resolve_delivery_target", params: ["pid": pid, "pid_resolution": "corroborated"]), operation: "agent.resolve_delivery_target")
                let surfaceID = target.surfaceId.lowercased(), workspaceID = target.workspaceId.lowercased()
                guard target.source == "pid", target.pidResolution == "corroborated",
                      owners[surfaceID]?.workspaceID == workspaceID, owners[surfaceID]?.kind == "terminal" else { continue }
                let resume: ResumeState = try decode(await rpc("surface.resume.get", params: ["workspace_id": workspaceID, "surface_id": surfaceID]), operation: "surface.resume.get")
                guard !resume.cleared, resume.workspaceId.lowercased() == workspaceID, resume.surfaceId.lowercased() == surfaceID,
                      let binding = resume.resumeBinding, binding.kind == "codex", let checkpoint = binding.checkpointId,
                      var record = records.filter({ $0.sessionId.lowercased() == checkpoint.lowercased() })
                        .max(by: { $0.updatedAtUnix < $1.updatedAtUnix }) else { continue }
                record.workspaceId = workspaceID; record.surfaceId = surfaceID
                active[surfaceID] = record
            } catch {
                try Task.checkCancellation()
                // Closed processes and unproven bindings remain unknown without hiding other agents.
            }
        }
        return active
    }

    private func snapshot(hierarchy: Tree, activeAgents: [String: HookSession], notices: NotificationList, feed: ActivityFeed) throws -> [Workspace] {
        let noticesBySurface = Dictionary(grouping: notices.notifications.filter { $0.surfaceId != nil }) {
            "\($0.workspaceId.lowercased()):\($0.surfaceId!.lowercased())"
        }
        let activityBySession = Dictionary(grouping: feed.items, by: { $0.workstreamId.lowercased() })
        let now = Self.timestamp(Date())
        var selection = Set<String>()
        var seenWorkspaceIDs = Set<String>()
        var seenSurfaceIDs = Set<String>()
        var result: [Workspace] = []

        for window in hierarchy.windows {
            guard UUID(uuidString: window.id) != nil else { throw CmuxError.badResponse("window identity") }
            for workspace in window.workspaces {
                let workspaceID = workspace.id.lowercased()
                guard UUID(uuidString: workspaceID) != nil, seenWorkspaceIDs.insert(workspaceID).inserted else {
                    throw CmuxError.badResponse("workspace identity")
                }
                if workspace.selected { selection.insert(workspaceID) }
                var surfaces: [Surface] = []
                for pane in workspace.panes {
                    for surface in pane.surfaces where surface.type == "terminal" || surface.type == "browser" {
                        let surfaceID = surface.id.lowercased()
                        guard UUID(uuidString: surfaceID) != nil, seenSurfaceIDs.insert(surfaceID).inserted else {
                            throw CmuxError.badResponse("surface identity")
                        }
                        let isFocused = pane.focused && (surface.selected || surface.focused)
                        if isFocused { selection.insert(surfaceID) }
                        let agent = activeAgents[surfaceID].flatMap { $0.workspaceId.lowercased() == workspaceID ? $0 : nil }
                        let matchingNotifications = noticesBySurface["\(workspaceID):\(surfaceID)"] ?? []
                        let events = agent.flatMap { agent in agent.agent.map { activityBySession["\($0)-\(agent.sessionId)".lowercased()] ?? [] } } ?? []
                        let activity = activityState(agent: agent, events: events, notices: matchingNotifications)
                        let status = activity.status
                        let completion = completionID(agent: agent, status: status, stoppedAt: activity.stoppedAt, notices: matchingNotifications)
                        let updated = max(agent?.updatedAtUnix ?? 0, matchingNotifications.compactMap { Self.date($0.createdAt)?.timeIntervalSince1970 }.max() ?? 0)
                        if selection.contains(surfaceID), !lastSelection.contains(surfaceID) { selectedAt[surfaceID] = now }
                        surfaces.append(Surface(id: surfaceID, kind: surface.type, focused: isFocused,
                                                selected: surface.selected, hasAgent: agent != nil,
                                                session: AgentSession(id: surfaceID, title: nonempty(surface.title, fallback: surface.type.capitalized),
                                                                      status: status == .idle && completion != nil ? .done : status,
                                                                      updatedAt: max(updated > 0 ? Self.timestamp(Date(timeIntervalSince1970: updated)) : "", selectedAt[surfaceID] ?? ""),
                                                                      environmentID: workspaceID, directory: agent?.cwd, completionID: completion)))
                    }
                }
                if selection.contains(workspaceID), !lastSelection.contains(workspaceID) { selectedAt[workspaceID] = now }
                let monitored = surfaces.filter(\.hasAgent).map(\.session)
                let status = SessionStatus.aggregate(monitored) ?? .unknown
                let completions = monitored.filter { $0.status == .done }.compactMap(\.completionID).sorted()
                let session = AgentSession(id: workspaceID, title: nonempty(workspace.title, fallback: "Workspace"),
                                           status: status, updatedAt: max(surfaces.map(\.session.updatedAt).max() ?? "", selectedAt[workspaceID] ?? ""),
                                           isPinned: workspace.pinned, environmentID: workspaceID,
                                           directory: surfaces.first(where: \.focused)?.session.directory ?? monitored.first?.directory,
                                           completionID: completions.isEmpty ? nil : completions.joined(separator: ","))
                result.append(Workspace(id: workspaceID, windowID: window.id.lowercased(), session: session, surfaces: surfaces))
            }
        }
        lastSelection = selection
        selectedAt = selectedAt.filter { seenWorkspaceIDs.contains($0.key) || seenSurfaceIDs.contains($0.key) }
        return result
    }

    private func activityState(agent: HookSession?, events: [ActivityItem], notices: [Notice]) -> (status: SessionStatus, stoppedAt: Double?) {
        guard let agent, agent.status != .unknown else { return (.unknown, nil) }
        let started = Self.date(agent.startedAt)?.timeIntervalSince1970 ?? 0
        let current = events.filter {
            $0.source == agent.agent && $0.created >= started - 1
        }.sorted { $0.created == $1.created ? $0.order < $1.order : $0.created < $1.created }
        if agent.status == .error { return (.error, nil) }
        if current.contains(where: { $0.status == "pending" && ["permissionRequest", "question", "exitPlan"].contains($0.kind) }) {
            return (.blocked, nil)
        }
        // Tool results also carry idle reminders and subagent exits. Only a parent
        // Stop ends a response; a subsequent prompt or tool start opens it again.
        let boundary = current.last { ["stop", "userPrompt", "toolUse", "sessionStart", "sessionEnd"].contains($0.kind) }
        guard let boundary else { return (agent.status, nil) }
        let fresh = boundary.created >= floor(agent.updatedAtUnix)
        if boundary.kind == "stop" {
            if agent.status == .blocked {
                let latestNotice = notices.max { $0.createdAt < $1.createdAt }
                let idleReminder = agent.agent == "claude" && agent.activePromptTurnId == nil
                    && latestNotice?.title == agent.agentDisplayName && latestNotice?.subtitle == "Waiting"
                    && (latestNotice.flatMap { Self.date($0.createdAt) }?.timeIntervalSince1970 ?? 0) >= floor(agent.updatedAtUnix)
                return idleReminder ? (.idle, boundary.created) : (.blocked, nil)
            }
            if fresh || agent.status == .idle { return (.idle, boundary.created) }
        } else if fresh && ["userPrompt", "toolUse"].contains(boundary.kind) {
            return (agent.status == .blocked && boundary.created <= agent.updatedAtUnix ? .blocked : .working, nil)
        }
        return (agent.status, nil)
    }

    private func completionID(agent: HookSession?, status: SessionStatus, stoppedAt: Double?, notices: [Notice]) -> String? {
        guard let agent, status == .idle else { return nil }
        let completed = notices.filter { notice in
            guard !notice.isRead, let date = Self.date(notice.createdAt)?.timeIntervalSince1970,
                  date >= (Self.date(agent.startedAt)?.timeIntervalSince1970 ?? 0) else { return false }
            // The feed supplies completion semantics even when a user's notification
            // command changes the title. Read state still belongs to cmux.
            if let stoppedAt, abs(date - stoppedAt) <= 2 { return true }
            let subtitle = notice.subtitle.lowercased()
            return agent.activePromptTurnId == nil && notice.title == agent.agentDisplayName
                && (subtitle == "completed" || subtitle.hasPrefix("completed in ")) && date >= agent.updatedAtUnix - 2
        }
        return completed.isEmpty ? nil : completed.map(\.id).sorted().joined(separator: ",")
    }

    private func decode<T: Decodable>(_ data: Data, operation: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data) }
        catch { throw CmuxError.badResponse(operation) }
    }

    private func nonempty(_ value: String, fallback: String) -> String { value.isEmpty ? fallback : value }
    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let dateFormatter = ISO8601DateFormatter()

    private static func timestamp(_ date: Date) -> String {
        fractionalDateFormatter.string(from: date)
    }
    private static func date(_ value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? dateFormatter.date(from: value)
    }

    private struct CurrentWorkspace: Decodable { let workspaceId: String }
    private struct PaneLayout: Decodable { let panes: [LayoutPane] }
    private struct LayoutPane: Decodable { let id: String; let focused: Bool; let selectedSurfaceId: String?; let pixelFrame: PaneFrame? }
    private struct PaneFrame: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
    private struct Workspace { let id: String; let windowID: String; let session: AgentSession; let surfaces: [Surface] }
    private struct Surface { let id: String; let kind: String; let focused: Bool; let selected: Bool; let hasAgent: Bool; let session: AgentSession }
    private struct Tree: Decodable { let windows: [WindowNode] }
    private struct Capabilities: Decodable { let methods: [String] }
    private struct WindowNode: Decodable { let id: String; let workspaces: [WorkspaceNode] }
    private struct WorkspaceNode: Decodable { let id: String; let title: String; let selected: Bool; let pinned: Bool; let panes: [PaneNode] }
    private struct PaneNode: Decodable { let focused: Bool; let surfaces: [SurfaceNode] }
    private struct SurfaceNode: Decodable { let id: String; let title: String; let type: String; let focused: Bool; let selected: Bool }
    private struct HookList: Decodable { let sessions: [HookSession] }
    private struct DeliveryTarget: Decodable { let source: String; let pidResolution: String; let workspaceId: String; let surfaceId: String }
    private struct ResumeState: Decodable {
        let workspaceId: String; let surfaceId: String; let cleared: Bool; let resumeBinding: ResumeBinding?
    }
    private struct ResumeBinding: Decodable { let kind: String; let checkpointId: String? }
    private struct HookSession: Decodable {
        let sessionId: String; var workspaceId: String; var surfaceId: String
        let agent: String?; let pid: Int?
        let agentDisplayName: String; let activeForSurface: Bool
        let startedAt: String; let updatedAtUnix: Double
        let runtimeStatus: String?; let agentLifecycle: String?
        let activePromptTurnId: String?; let lastPromptTurnId: String?; let cwd: String?

        var status: SessionStatus {
            switch runtimeStatus ?? agentLifecycle {
            case "running": return .working
            case "needsInput": return .blocked
            case "error": return .error
            case "idle": return .idle
            default: return .unknown
            }
        }
    }
    private struct ActivityFeed: Decodable {
        let items: [ActivityItem]
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var items = try container.decode([ActivityItem].self, forKey: .items)
            for index in items.indices { items[index].order = index }
            self.items = items
        }
        private enum CodingKeys: String, CodingKey { case items }
    }
    private struct ActivityItem: Decodable {
        let workstreamId: String; let source: String; let kind: String; let status: String; let createdAt: String
        var order = 0
        @MainActor var created: Double { CmuxClient.date(createdAt)?.timeIntervalSince1970 ?? 0 }
        private enum CodingKeys: String, CodingKey { case workstreamId, source, kind, status, createdAt }
    }
    private struct NotificationList: Decodable { let notifications: [Notice] }
    private struct Notice: Decodable {
        let id: String; let workspaceId: String; let surfaceId: String?; let isRead: Bool
        let title: String; let subtitle: String; let createdAt: String
    }
}

enum CmuxCommand {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 8) async throws -> Data {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try execute(executable: executable, arguments: arguments,
                                                                   timeout: timeout, cancellation: cancellation) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(executable: String, arguments: [String], timeout: TimeInterval, cancellation: Cancellation) throws -> Data {
        if cancellation.isCancelled { throw CancellationError() }
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw CmuxError.missingCLI(executable) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("micro-cmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw CmuxError.missingCLI(executable) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if cancellation.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                kill(process.processIdentifier, SIGKILL)
                if cancellation.isCancelled { throw CancellationError() }
                throw CmuxError.timeout
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: errorURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 2048) ?? Data()
            throw CmuxError.commandFailed(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let maximumOutput = 16 * 1024 * 1024
        let data = try reader.read(upToCount: maximumOutput + 1) ?? Data()
        guard data.count <= maximumOutput else { throw CmuxError.badResponse("oversized command output") }
        return data
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }
}
