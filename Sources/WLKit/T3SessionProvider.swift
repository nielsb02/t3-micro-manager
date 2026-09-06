import AppKit

@MainActor public final class T3SessionProvider: SessionProvider {
    private let settings: T3ConnectionSettings
    private let client: T3Client

    public init(settings: T3ConnectionSettings) {
        self.settings = settings
        client = T3Client(settings: settings)
    }

    public func listSessions() async throws -> [AgentSession] {
        try await client.listSessions()
    }

    public func openSession(_ session: AgentSession) async throws {
        switch settings.openTarget {
        case .desktop:
            try await T3DesktopClient.openThread(session, settings: settings)
        case .browser:
            guard NSWorkspace.shared.open(try client.sessionURL(session)) else {
                throw ConfigurationError.invalid("Could not open the T3 session URL.")
            }
        }
    }
}
