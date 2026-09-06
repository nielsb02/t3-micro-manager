import Foundation

public enum SessionAcknowledgementMode: Sendable {
    case local, provider
}

/// Providers own application connections. They never receive the pad, keymap, or LED state.
@MainActor public protocol SessionProvider: AnyObject {
    var acknowledgementMode: SessionAcknowledgementMode { get }
    var requiresEmulator: Bool { get }
    func listSessions() async throws -> [AgentSession]
    func openSession(_ session: AgentSession) async throws
}

public extension SessionProvider {
    var acknowledgementMode: SessionAcknowledgementMode { .local }
    var requiresEmulator: Bool { false }

    func validatedSessions() async throws -> [AgentSession] {
        let sessions = try await listSessions()
        guard sessions.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty }),
              Set(sessions.map(\.id)).count == sessions.count else {
            throw SessionProviderError.invalidSnapshot
        }
        return sessions
    }
}

public struct SessionAction: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public enum SessionInput: Equatable, Sendable {
    /// Text is inserted without implicitly submitting it.
    case text(String)
    /// A provider-defined action ID advertised in its capabilities.
    case action(String)
}

public struct SessionInputCapabilities: Equatable, Sendable {
    public let acceptsText: Bool
    public let actions: [SessionAction]

    public init(acceptsText: Bool = false, actions: [SessionAction] = []) {
        self.acceptsText = acceptsText
        self.actions = actions
    }

    public func supports(_ input: SessionInput) -> Bool {
        switch input {
        case .text: return acceptsText
        case .action(let id): return actions.contains { $0.id == id }
        }
    }
}

/// Optional: read/open-only providers do not need an input implementation.
@MainActor public protocol SessionInputProvider: SessionProvider {
    var inputCapabilities: SessionInputCapabilities { get }
    func sendInput(_ input: SessionInput, to session: AgentSession) async throws
}

public enum SessionProviderError: LocalizedError {
    case invalidSnapshot, unsupportedInput, unavailableSession

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "The provider returned missing or duplicate session identities."
        case .unsupportedInput: return "This provider does not support that input."
        case .unavailableSession: return "This session is no longer available on the current connection."
        }
    }
}

public typealias SessionProviderFactory = @MainActor (SessionConfiguration) -> any SessionProvider

public enum SessionProviders {
    @MainActor public static func make(configuration: SessionConfiguration) -> any SessionProvider {
        switch configuration.provider {
        case .t3: return T3SessionProvider(settings: configuration.t3)
        case .herdr: return HerdrSessionProvider()
        case .demo: return DemoSessionProvider()
        }
    }
}
