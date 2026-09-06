import Foundation

@MainActor public final class DemoSessionProvider: SessionProvider {
    public let requiresEmulator = true
    private var tick = 0

    public init() {}

    public func listSessions() async throws -> [AgentSession] {
        tick += 1
        return [
            AgentSession(id: "demo-build", title: "Build the dashboard",
                         status: tick % 16 < 10 ? .working : .done, updatedAt: "3",
                         isPinned: true, completionID: "build-\(tick / 16)"),
            AgentSession(id: "demo-review", title: "Review a change", status: .blocked, updatedAt: "2"),
            AgentSession(id: "demo-idle", title: "Plan the next task", status: .idle, updatedAt: "1")
        ]
    }

    public func openSession(_ session: AgentSession) async throws {}
}
