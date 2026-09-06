import AppKit

@MainActor public final class HerdrSessionProvider: SessionInputProvider {
    public let acknowledgementMode: SessionAcknowledgementMode = .provider
    public let inputCapabilities = SessionInputCapabilities(acceptsText: true)
    private var panes: [String: String] = [:]

    public init() {}

    public func listSessions() async throws -> [AgentSession] {
        let agents = try await HerdrClient.listAgents()
        var nextPanes: [String: String] = [:]
        let sessions = agents.enumerated().compactMap { offset, agent -> AgentSession? in
            guard let id = agent.focusTarget, !id.isEmpty else { return nil }
            nextPanes[id] = agent.paneID
            return AgentSession(id: id, title: agent.shortName,
                                status: SessionStatus(rawValue: agent.status) ?? .unknown,
                                updatedAt: String(format: "%08d", 99999999 - offset),
                                directory: agent.workingDirectory)
        }
        panes = nextPanes
        return sessions
    }

    public func openSession(_ session: AgentSession) async throws {
        try await HerdrClient.focusAgent(session.id)
        let bundle = ProcessInfo.processInfo.environment["WL_TERMINAL_BUNDLE_ID"] ?? "com.mitchellh.ghostty"
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate(options: [])
    }

    public func sendInput(_ input: SessionInput, to session: AgentSession) async throws {
        guard case .text(let text) = input else { throw SessionProviderError.unsupportedInput }
        guard let pane = panes[session.id], !pane.isEmpty else { throw SessionProviderError.unavailableSession }
        try await HerdrClient.sendText(paneID: pane, text: text)
    }
}
