import Foundation

public enum SessionAssignments {
    public static func assign(_ sessions: [AgentSession], configuration: SessionConfiguration,
                              previous: [Int: String] = [:]) -> [Int: String] {
        let available = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Int: String] = [:]
        var used = Set<String>()
        let keys = configuration.sessionKeys
        if configuration.selection != .recent {
            for key in keys {
                if let id = configuration.pinnedSessions[key] {
                    // Reserve explicit pins even while a session is unavailable.
                    if available[id] != nil && used.insert(id).inserted { result[key] = id }
                }
            }
        }
        let reserved = configuration.selection == .recent ? Set<Int>() : Set(configuration.pinnedSessions.keys)
        let eligible = sessions.filter { configuration.selection != .pinned || $0.isPinned }
            .sorted { lhs, rhs in
                if configuration.selection == .mixed && lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
            }
        // Keep an active session on its current key as the recent list changes.
        for key in keys where result[key] == nil && !reserved.contains(key) {
            if let id = previous[key], let session = available[id],
               session.status.retainsAssignment, eligible.contains(where: { $0.id == id }),
               used.insert(id).inserted { result[key] = id }
        }
        for key in keys where result[key] == nil && !reserved.contains(key) {
            if let next = eligible.first(where: { !used.contains($0.id) }) {
                result[key] = next.id; used.insert(next.id)
            }
        }
        return result
    }
}
