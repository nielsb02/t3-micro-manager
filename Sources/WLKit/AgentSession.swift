import Foundation

public enum SessionStatus: String, CaseIterable, Sendable {
    case blocked, working, done, idle, error, unknown

    public var title: String {
        switch self {
        case .blocked: return "Needs you"
        case .working: return "Working"
        case .done: return "Finished"
        case .idle: return "Idle"
        case .error: return "Error"
        case .unknown: return "Disconnected"
        }
    }

    public var retainsAssignment: Bool { self == .working || self == .blocked }

    public static func aggregate(_ sessions: [AgentSession]) -> Self? {
        let present = Set(sessions.map(\.status))
        return [Self.error, .blocked, .working, .unknown, .done, .idle].first(where: present.contains)
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: SessionStatus
    public var updatedAt: String
    public var isPinned: Bool
    public var environmentID: String?
    public var directory: String?
    /// Identifies a completed response, independently of title, pin, and other metadata edits.
    public var completionID: String?
    /// Position in the provider's active list; nil excludes it from App order mode.
    public var providerOrder: Int?

    public init(id: String, title: String, status: SessionStatus, updatedAt: String = "",
                isPinned: Bool = false, environmentID: String? = nil, directory: String? = nil,
                completionID: String? = nil, providerOrder: Int? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.environmentID = environmentID
        self.directory = directory
        self.completionID = completionID
        self.providerOrder = providerOrder
    }

    var completionRevision: String { completionID ?? updatedAt }
}

struct SessionAcknowledgements {
    private var opened: [String: String] = [:]

    mutating func acknowledge(_ session: AgentSession) {
        guard session.status == .done else { return }
        opened[session.id] = session.completionRevision
    }

    mutating func applying(to sessions: [AgentSession]) -> [AgentSession] {
        let ids = Set(sessions.map(\.id))
        opened = opened.filter { ids.contains($0.key) }
        return sessions.map { session in
            var result = session
            if session.status == .done, opened[session.id] == session.completionRevision {
                result.status = .idle
            } else if session.status == .working {
                opened[session.id] = nil
            }
            return result
        }
    }
}
