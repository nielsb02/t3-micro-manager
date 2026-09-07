import AppKit
import SwiftUI
import WLKit

@MainActor final class CmuxCommandWindowController: NSObject, NSWindowDelegate {
    static let shared = CmuxCommandWindowController()
    private var window: NSWindow?
    private var model: CmuxCommandModel?

    func show(_ bridge: BridgeController) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let model = CmuxCommandModel(bridge: bridge) { [weak self] in self?.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "cmux voice commands"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: CmuxCommandView(model: model))
        self.window = window; self.model = model
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func handle(_ action: SessionControlAction) -> Bool {
        guard window?.isVisible == true else { return false }
        if action == .submit { model?.run(); return true }
        if action == .escape || action == .commands { close(); return true }
        return false
    }
    func close() { window?.close(); window = nil; model = nil }
    func windowWillClose(_ notification: Notification) { window = nil; model = nil }
}

@MainActor private final class CmuxCommandModel: ObservableObject {
    @Published var text = ""
    @Published var error: String?
    @Published var busy = false
    private weak var bridge: BridgeController?
    private let layerID: String
    private let close: () -> Void
    init(bridge: BridgeController, close: @escaping () -> Void) {
        self.bridge = bridge; layerID = bridge.configuration.selectedLayerID; self.close = close
    }
    func run() {
        guard !busy, let bridge, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; error = nil
        let command = text
        Task {
            do { try await bridge.executeCmuxCommand(command, layerID: layerID); close() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct CmuxCommandView: View {
    @ObservedObject var model: CmuxCommandModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use your dictation key, then press Submit.").font(.headline)
            TextField("For example: next workspace", text: $model.text)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit { model.run() }
            Text("Commands: next/previous workspace, next/previous terminal, left, right, up, down, attention, or open followed by an exact workspace or tab name.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Commands run only when you submit this panel.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Run command") { model.run() }.buttonStyle(.borderedProminent).disabled(model.busy || model.text.isEmpty)
            }
        }.padding(22).frame(width: 570).onAppear { focused = true }
    }
}
