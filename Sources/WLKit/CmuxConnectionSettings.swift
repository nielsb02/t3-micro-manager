import Foundation

public enum CmuxSessionScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case workspaces, workspace

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .workspaces: return "Workspaces"
        case .workspace: return "Tabs in one workspace"
        }
    }
}

public struct CmuxConnectionSettings: Codable, Equatable, Sendable {
    public var cliPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    public var socketPath = ""
    public var scope: CmuxSessionScope = .workspaces
    public var workspaceID = ""

    public init() {}
}
