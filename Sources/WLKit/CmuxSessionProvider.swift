import AppKit

@MainActor public final class CmuxSessionProvider: SessionInputProvider, SessionControlProvider {
    public let acknowledgementMode: SessionAcknowledgementMode = .provider
    public var inputCapabilities: SessionInputCapabilities { CmuxClient.inputCapabilities }
    private let client: CmuxClient

    public init(settings: CmuxConnectionSettings) {
        client = CmuxClient(settings: settings)
    }

    public func listSessions() async throws -> [AgentSession] {
        try await client.listSessions()
    }

    public func workspaces() async throws -> [AgentSession] {
        try await client.workspaces()
    }

    public func openSession(_ session: AgentSession) async throws {
        try await client.openSession(session)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app")
            .first?.activate(options: [])
    }

    public func sendInput(_ input: SessionInput, to session: AgentSession) async throws {
        try await client.sendInput(input, to: session)
    }
    public func performControl(_ action: SessionControlAction, text: String = "") async throws {
        try await client.performControl(action, text: text)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app").first?.activate(options: [])
    }
    public func executeCommand(_ text: String) async throws {
        try await client.executeCommand(text)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app").first?.activate(options: [])
    }

}
