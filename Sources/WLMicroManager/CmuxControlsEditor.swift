import SwiftUI
import WLKit

struct CmuxControlsEditor: View {
    @Binding var bindings: [SessionControlBinding]
    let sessionKeys: [Int]
    let reserveCodexSlots: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(sessionKeys.count + bindings.count) of \(reserveCodexSlots ? 14 : 20) slots used")
                        .font(.callout).foregroundStyle(overCapacity ? .red : .secondary)
                    Spacer()
                    Button("Use navigation preset") {
                        bindings = SessionControlBinding.navigationPreset.filter { !sessionKeys.contains($0.inputID) }
                    }
                }
                Text("The preset turns the dial through tabs, presses it to switch between tabs and workspaces, moves pane focus with the joystick, and uses key 7 to submit.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach([Pad.dialUpID, Pad.dialDownID, Pad.dialPressID, Pad.joyNorthID, Pad.joyWestID, Pad.joySouthID, Pad.joyEastID], id: \.self) { input in
                    controlRow(input)
                }
                DisclosureGroup("Spare buttons & prompt text") {
                    VStack(spacing: 10) {
                        ForEach((0..<13).filter { !sessionKeys.contains($0) }, id: \.self) { input in controlRow(input) }
                    }.padding(.top, 10)
                }
                Text("Keep your Wispr Flow shortcut on an unassigned key in Input. Dictation types into the focused terminal. Submit is a separate action. Bind Open voice command panel to dictate navigation commands or open a workspace by name.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if overCapacity {
                    Label("Remove a control or session key before applying.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("Applying saves and verifies the original dial, joystick and button bindings. Restore returns those bindings, while preserving later edits made in Input.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        } label: {
            Label("cmux controls & voice", systemImage: "dial.low").font(.headline)
        }
    }
    private var overCapacity: Bool { sessionKeys.count + bindings.count > (reserveCodexSlots ? 14 : 20) }
    private func controlRow(_ input: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(SessionControlBinding.title(for: input), selection: action(input)) {
                Text("Keep existing binding").tag(Optional<SessionControlAction>.none)
                ForEach(SessionControlAction.allCases, id: \.self) { value in Text(value.title).tag(Optional(value)) }
            }
            if bindings.first(where: { $0.inputID == input })?.action == .insertText {
                TextField("Prompt text, inserted without Enter", text: Binding(
                    get: { bindings.first { $0.inputID == input }?.text ?? "" },
                    set: { value in if let index = bindings.firstIndex(where: { $0.inputID == input }) { bindings[index].text = value } }
                ), axis: .vertical).lineLimit(2...5)
            }
        }
    }
    private func action(_ input: Int) -> Binding<SessionControlAction?> {
        Binding(get: { bindings.first { $0.inputID == input }?.action }, set: { action in
            let text = bindings.first { $0.inputID == input }?.text ?? ""
            bindings.removeAll { $0.inputID == input }
            if let action { bindings.append(.init(inputID: input, action: action, text: text)) }
        })
    }
}
