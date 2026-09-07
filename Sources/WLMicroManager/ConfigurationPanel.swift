import AppKit
import SwiftUI
import WLKit
import UniformTypeIdentifiers

@MainActor
final class ConfigurationWindowController: NSObject, NSWindowDelegate {
    static let shared = ConfigurationWindowController()
    private var window: NSWindow?

    func show(_ bridge: BridgeController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 730, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Configure Micro Manager"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ConfigurationPanel(bridge: bridge))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct ConfigurationPanel: View {
    @ObservedObject var bridge: BridgeController
    @State private var draft: SessionConfiguration
    @State private var baseline: SessionConfiguration
    @State private var pairingCode = ""
    @State private var testedSessions: [AgentSession]?
    @State private var busy: String?
    @State private var feedback: String?
    @State private var feedbackIsError = false

    init(bridge: BridgeController) {
        self.bridge = bridge
        _draft = State(initialValue: bridge.configuration)
        _baseline = State(initialValue: bridge.configuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your sessions, on your Micro").font(.title2).bold()
                    Text("Choose a connection, layer, and session keys. Manage ordinary shortcuts in Work Louder Input.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "keyboard").font(.system(size: 30)).foregroundStyle(.tint)
            }
            .padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionSection
                    deviceSection
                    assignmentSection
                }
                .padding(22)
                .disabled(busy != nil || bridge.isBusy)
            }
            Divider()
            footer
        }
        .frame(minWidth: 650, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: draft.provider) { _ in testedSessions = nil; feedback = nil }
        .onChange(of: draft.t3) { _ in testedSessions = nil }
        .onChange(of: bridge.configuration) { configuration in
            if draft == baseline { draft = configuration }
            baseline = configuration
        }
    }

    private var connectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $draft.provider) {
                    ForEach(SessionProviderKind.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                if draft.provider == .t3 {
                    labeledField("Server URL") {
                        TextField("http://127.0.0.1:3773", text: $draft.t3.baseURL)
                        Button("Discover") {
                            if let endpoint = T3Client.discoverLocalEndpoint() {
                                draft.t3.baseURL = endpoint
                                feedback = "Found your local T3 server."
                                feedbackIsError = false
                            } else {
                                feedback = "No local T3 server found. Start T3 or enter its address."
                                feedbackIsError = true
                            }
                        }
                    }
                    Text("Use your Mac's local T3 server address for session status.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Open sessions in", selection: $draft.t3.openTarget) {
                        ForEach(T3OpenTarget.allCases, id: \.self) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    Text(draft.t3.openTarget == .desktop
                         ? "Selects the exact session in your existing desktop window. Requires the T3 build with desktop navigation support."
                         : "Opens the session in your browser. Pair that browser with T3 once if needed.")
                        .font(.caption).foregroundStyle(.secondary)
                    if draft.t3.openTarget == .desktop {
                        labeledField("Desktop app") {
                            TextField("Use running T3 (optional)", text: $draft.t3.desktopApplicationPath)
                            Button("Choose…") { chooseDesktopApplication() }
                            if !draft.t3.desktopApplicationPath.isEmpty {
                                Button("Clear") { draft.t3.desktopApplicationPath = "" }
                            }
                        }
                        Text("Choose the T3 build to open when needed. Leave blank to use the running desktop. A different copy already running will be reported.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    labeledField("Access token") {
                        SecureField("Paste a token, or pair below", text: $draft.t3.bearerToken)
                    }
                    DisclosureGroup("Pair with T3") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Create a pairing link in T3 Settings → Connections, then paste the link or token here.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                SecureField("Pairing link or token", text: $pairingCode)
                                Button("Pair") { pair() }
                                    .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(.top, 8)
                    }
                    DisclosureGroup("Advanced connection settings") {
                        labeledField("Environment ID") {
                            TextField("Discover automatically", text: $draft.t3.environmentID)
                        }
                        .padding(.top, 8)
                        if draft.t3.openTarget == .desktop {
                            labeledField("Desktop socket") {
                                TextField(T3DesktopClient.defaultSocketPath(), text: $draft.t3.desktopSocketPath)
                            }
                        }
                    }
                } else if draft.provider == .herdr {
                    Text("Connects to Herdr through its local control socket. Start Herdr before testing.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Sample sessions for the virtual pad. Use “Try demo” in the menu to launch it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Test connection") { testConnection() }
                    if let testedSessions {
                        Label("\(testedSessions.count) sessions found", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                if let testedSessions, !testedSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(testedSessions.prefix(4)) { session in
                            HStack {
                                Circle().fill(sessionColor(session.status)).frame(width: 7, height: 7)
                                Text(session.title).lineLimit(1)
                                Spacer()
                                Text(sessionStatusLabel(session.status)).foregroundStyle(.secondary)
                                Button("Open") {
                                    let settings = draft
                                    run("Opening session…") {
                                        try await bridge.openSession(session, using: settings)
                                        return "Opened \(session.title)."
                                    }
                                }
                            }
                            .font(.caption)
                        }
                        if testedSessions.count > 4 {
                            Text("And \(testedSessions.count - 4) more…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Connection", systemImage: "network").font(.headline)
        }
    }

    private var deviceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bridge.deviceConnected ? bridge.deviceName : "Choose the layer you want to use")
                            .font(.callout)
                        if !bridge.firmware.isEmpty {
                            Text(bridge.firmware).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Read layers from Micro") {
                        run("Reading device…") {
                            await bridge.inspectDevice()
                            try checkBridgeError()
                            return "Read \(bridge.availableLayers.count) layers."
                        }
                    }
                }
                Text("Session keys use separate agent slots from Codex. If you applied the first build, save and apply once more to update those bindings.")
                    .font(.caption).foregroundStyle(.secondary)
                if bridge.availableLayers.isEmpty {
                    Text("Connect your Micro and read its layers, or enable the virtual pad from the menu.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Layer", selection: selectedLayerID) {
                        Text("Select a layer…").tag("")
                        ForEach(bridge.availableLayers) { layer in
                            Text(layer.title).tag(layer.id)
                        }
                    }
                }
                HStack(alignment: .center, spacing: 24) {
                    SessionKeyGrid(
                        selected: Set(draft.sessionKeys),
                        colors: [:],
                        keyWidth: 48,
                        keyHeight: 35,
                        onPress: toggleKey
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Click the keys to use for sessions.").font(.callout).bold()
                        Text("\(draft.sessionKeys.count) selected")
                            .font(.caption).foregroundStyle(.tint)
                        Text("Keep Wispr Flow and Enter on unselected keys. Configure ordinary shortcuts in Input.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The wide bottom key has two positions, 10 and 11. Both are left free by default.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if draft.assignedButtonKeys.contains(10) || draft.assignedButtonKeys.contains(11) {
                            Text("Selecting the wide key replaces its existing shortcut on this layer.")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                actionButtonSection
                if let layer = selectedLayer {
                    DisclosureGroup("Review selected button changes") {
                        VStack(spacing: 5) {
                            ForEach(draft.assignedButtonKeys.sorted(), id: \.self) { key in
                                HStack {
                                    Text("Key \(key)").frame(width: 50, alignment: .leading)
                                    Text(existingBinding(key, layer: layer))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    Text(draft.actionButtons[key]?.title ?? "Session control")
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                Toggle("Use the dial and joystick down in T3", isOn: $draft.microControlsEnabled)
                    .toggleStyle(.checkbox)
                if draft.microControlsEnabled {
                    Text("Joystick down toggles composer focus. In the composer, rotate to choose a setting and press to edit or confirm it. Outside the composer, rotate to scroll and press to jump to the latest message. T3 must be frontmost.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Apply replaces only dial rotation, dial press, and joystick down alongside your assigned buttons. Restore controls returns their saved bindings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if draft.assignedButtonKeys.count > 10 {
                        Text("Assign at most 10 session and action buttons in total to leave room for these four controls.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if draft.provider != .t3 || draft.t3.openTarget != .desktop {
                        Text("Choose the T3 desktop connection to enable these controls.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Toggle("Use the ambient light for overall session status", isOn: $draft.driveAmbient)
                    .toggleStyle(.checkbox)
                Text("The bridge is active only on the selected layer. Apply saves a backup before changing selected controls.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let backup = bridge.backupPath {
                    HStack {
                        Label("Mapping backup available", systemImage: "externaldrive.badge.checkmark")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show backup") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup)])
                        }
                        Button("Restore controls") { restoreMapping() }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Layer & keys", systemImage: "keyboard").font(.headline)
        }
    }

    private var actionButtonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spare button actions").font(.callout).bold()
            Text("Assign a T3 action to any button that is not used for sessions. Keep Input binding leaves its shortcut unchanged. Actions run only while your T3 desktop is frontmost.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach((0...12).filter { !draft.sessionKeys.contains($0) }, id: \.self) { key in
                Picker("Key \(key)", selection: actionBinding(key)) {
                    Text("Keep Input binding").tag("")
                    ForEach(T3MicroAction.assignableActions, id: \.self) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
            }
            if draft.actionButtons[10] != nil || draft.actionButtons[11] != nil || draft.actionButtons[12] != nil {
                Text("Assigning a bottom-row button replaces its current microphone or Enter shortcut. Leave it on Keep Input binding to preserve that shortcut.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !draft.actionButtons.isEmpty && (draft.provider != .t3 || draft.t3.openTarget != .desktop) {
                Text("Choose the T3 desktop connection to use these actions.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func actionBinding(_ key: Int) -> Binding<String> {
        Binding(
            get: { draft.actionButtons[key]?.rawValue ?? "" },
            set: { draft.actionButtons[key] = T3MicroAction(rawValue: $0) }
        )
    }

    private var assignmentSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Fill selected keys with", selection: $draft.selection) {
                    ForEach(SessionSelectionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(selectionDescription).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.selection != .recent {
                    ForEach(draft.sessionKeys, id: \.self) { key in
                        Picker("Key \(key)", selection: pinBinding(key)) {
                            Text(draft.selection == .pinned ? "Use a provider-pinned session" : "Fill automatically").tag("")
                            if let pinned = draft.pinnedSessions[key], !sessionChoices.contains(where: { $0.id == pinned }) {
                                Text("Unavailable session (saved pin)").tag(pinned)
                            }
                            ForEach(sessionChoices) { session in
                                Text(session.title).tag(session.id)
                            }
                        }
                    }
                    if sessionChoices.isEmpty {
                        Text("Test the connection to choose sessions to pin.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Session assignments", systemImage: "pin").font(.headline)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
            } else if let feedback {
                Label(feedback, systemImage: feedbackIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(feedbackIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(draft == baseline ? "Settings saved" : "Unsaved settings")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save settings") { saveSettings(apply: false) }
                    .disabled(busy != nil || bridge.isBusy || draft.sessionKeys.isEmpty)
                Button("Save & apply controls") { saveSettings(apply: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy != nil || bridge.isBusy || draft.target == nil || draft.sessionKeys.isEmpty)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var selectedLayer: DeviceLayer? {
        bridge.availableLayers.first { $0.target == draft.target }
    }

    private var selectedLayerID: Binding<String> {
        Binding(
            get: { selectedLayer?.id ?? "" },
            set: { id in draft.target = bridge.availableLayers.first { $0.id == id }?.target }
        )
    }

    private var sessionChoices: [AgentSession] {
        testedSessions ?? (draft.hasSameConnection(as: bridge.configuration) ? bridge.sessions : [])
    }

    private var selectionDescription: String {
        switch draft.selection {
        case .pinned:
            return "Choose fixed sessions per key. Unassigned keys use sessions pinned in your provider."
        case .recent:
            return "Fill keys with recently active sessions. Working sessions keep their current key."
        case .mixed:
            return "Keep chosen sessions on fixed keys and fill the rest with recently active sessions."
        }
    }

    private func pinBinding(_ key: Int) -> Binding<String> {
        Binding(
            get: { draft.pinnedSessions[key] ?? "" },
            set: { value in draft.pinnedSessions[key] = value.isEmpty ? nil : value }
        )
    }

    private func toggleKey(_ key: Int) {
        guard draft.actionButtons[key] == nil else {
            feedback = "Set Key \(key) to Keep Input binding before using it for sessions."
            feedbackIsError = true
            return
        }
        if draft.sessionKeys.contains(key) {
            draft.sessionKeys.removeAll { $0 == key }
            draft.pinnedSessions[key] = nil
        } else {
            draft.sessionKeys.append(key)
            let order = Pad.displayRows.flatMap { $0 }
            draft.sessionKeys.sort { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
        }
    }

    private func existingBinding(_ key: Int, layer: DeviceLayer) -> String {
        guard let position = Pad.position(of: key), layer.keymap.indices.contains(position.row),
              layer.keymap[position.row].indices.contains(position.column) else { return "Unavailable" }
        return layer.keymap[position.row][position.column]
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).frame(width: 105, alignment: .leading)
            content()
        }
    }

    private func testConnection() {
        let settings = draft
        run("Connecting to \(settings.provider.title)…") {
            testedSessions = try await bridge.testConnection(settings)
            return "Connected. \(testedSessions?.count ?? 0) sessions available."
        }
    }

    private func chooseDesktopApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose your T3 desktop app"
        panel.prompt = "Choose T3"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try T3DesktopClient.applicationURL(path: url.path)
            draft.t3.desktopApplicationPath = url.path
            feedback = "Selected \(url.lastPathComponent). Test a session, then save settings."
            feedbackIsError = false
        } catch {
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }

    private func pair() {
        let settings = draft.t3
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        run("Pairing with T3…") {
            draft.t3.bearerToken = try await T3Client(settings: settings).pair(code: code)
            pairingCode = ""
            return "Paired with T3. Test the connection, then save your settings."
        }
    }

    private func saveSettings(apply: Bool) {
        let settings = draft
        run(apply ? "Backing up and applying selected controls…" : "Saving settings…") {
            try settings.validate()
            await bridge.saveConfiguration(settings)
            try checkBridgeError()
            baseline = bridge.configuration
            if apply {
                await bridge.applyMapping()
                try checkBridgeError()
                return "Selected controls applied. Enable Micro Manager and switch to your chosen layer."
            }
            return "Settings saved. Device bindings are changed with Apply."
        }
    }

    private func restoreMapping() {
        run("Restoring control bindings…") {
            await bridge.restoreMapping()
            try checkBridgeError()
            return "Original control bindings restored."
        }
    }

    private func checkBridgeError() throws {
        if let message = bridge.lastError { throw ConfigurationError.invalid(message) }
    }

    private func run(_ label: String, operation: @escaping @MainActor () async throws -> String) {
        guard busy == nil else { return }
        busy = label
        feedback = nil
        Task { @MainActor in
            do {
                feedback = try await operation()
                feedbackIsError = false
            } catch {
                feedback = error.localizedDescription
                feedbackIsError = true
            }
            busy = nil
        }
    }
}

struct SessionKeyGrid: View {
    var selected: Set<Int>
    var colors: [Int: Color]
    var keyWidth: CGFloat
    var keyHeight: CGFloat
    var onPress: (Int) -> Void

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(Pad.displayRows.prefix(3).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { key in keyButton(key) }
                }
            }
            HStack(spacing: 5) {
                Bowtie().fill(Color.secondary.opacity(0.25))
                    .frame(width: 17, height: 10).frame(width: keyWidth, height: keyHeight)
                HStack(spacing: 1) {
                    keyButton(10)
                    keyButton(11)
                }
                keyButton(12)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func keyButton(_ key: Int) -> some View {
        let isSelected = selected.contains(key)
        return Button { onPress(key) } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(colors[key] ?? (isSelected ? Color.accentColor.opacity(0.23) : Color.secondary.opacity(0.08)))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.2), lineWidth: 1)
                }
                .overlay {
                    Text("\(key)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(colors[key] == nil ? Color.primary : Color.black.opacity(0.8))
                }
                .frame(width: keyWidth, height: keyHeight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Key \(key), \(isSelected ? "selected" : "managed in Input")")
        .help("Key \(key)")
    }
}
