import Foundation

public enum SessionControlAction: String, Codable, CaseIterable, Sendable {
    case nextTab, previousTab, nextWorkspace, previousWorkspace
    case focusLeft, focusRight, focusUp, focusDown, nextAttention
    case toggleDialMode, commands, submit, escape, interrupt, insertText

    public var title: String {
        switch self {
        case .nextTab: return "Next terminal or browser tab"
        case .previousTab: return "Previous terminal or browser tab"
        case .nextWorkspace: return "Next workspace"
        case .previousWorkspace: return "Previous workspace"
        case .focusLeft: return "Focus left pane"
        case .focusRight: return "Focus right pane"
        case .focusUp: return "Focus pane above"
        case .focusDown: return "Focus pane below"
        case .nextAttention: return "Next agent needing attention"
        case .toggleDialMode: return "Switch dial between tabs and workspaces"
        case .commands: return "Open voice command panel"
        case .submit: return "Submit prompt / Enter"
        case .escape: return "Escape"
        case .interrupt: return "Interrupt / Ctrl-C"
        case .insertText: return "Insert text without submitting"
        }
    }
}

public struct SessionControlBinding: Codable, Equatable, Identifiable, Sendable {
    public var inputID: Int
    public var action: SessionControlAction
    public var text: String
    public var id: Int { inputID }
    public init(inputID: Int, action: SessionControlAction, text: String = "") {
        self.inputID = inputID; self.action = action; self.text = text
    }
    public static func title(for input: Int) -> String { Pad.inputTitle(input) }
    public static let navigationPreset: [Self] = [
        .init(inputID: Pad.dialUpID, action: .nextTab),
        .init(inputID: Pad.dialDownID, action: .previousTab),
        .init(inputID: Pad.dialPressID, action: .toggleDialMode),
        .init(inputID: Pad.joyNorthID, action: .focusUp),
        .init(inputID: Pad.joyWestID, action: .focusLeft),
        .init(inputID: Pad.joySouthID, action: .focusDown),
        .init(inputID: Pad.joyEastID, action: .focusRight),
        .init(inputID: 7, action: .submit),
    ]
}

@MainActor public protocol SessionControlProvider: SessionProvider {
    func performControl(_ action: SessionControlAction, text: String) async throws
    func executeCommand(_ text: String) async throws
}
