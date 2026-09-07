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
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 860),
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
    @StateObject private var workspaceLoader = CmuxWorkspaceLoader()

    init(bridge: BridgeController) {
        self.bridge = bridge
        _draft = State(initialValue: bridge.configuration)
        _baseline = State(initialValue: bridge.configuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your apps, one Micro").font(.title2).bold()
                    Text("Give each app its own layer. Your keys and lights follow the active layer on your Micro.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "square.3.layers.3d").font(.system(size: 30)).foregroundStyle(.tint)
            }
            .padding(22)
            codexSection
                .padding(.horizontal, 22).padding(.bottom, 18)
                .disabled(busy != nil || bridge.isBusy)
            Divider()
            HStack(spacing: 0) {
                layerSidebar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        layerHeading
                        connectionSection
                        assignmentSection
                        deviceSection
                        if draft.provider == .cmux {
                            CmuxControlsEditor(bindings: $draft.controlBindings, sessionKeys: draft.sessionKeys, reserveCodexSlots: draft.reserveCodexSlots)
                        }
                    }
                    .padding(22)
                }
            }
            .disabled(busy != nil || bridge.isBusy)
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: draft.selectedLayerID) { _ in
            testedSessions = nil
            pairingCode = ""
            feedback = nil
        }
        .onChange(of: draft.provider) { provider in
            testedSessions = nil; feedback = nil
            if !SessionSelectionMode.available(for: provider).contains(draft.selection) { draft.selection = .recent }
        }
        .onChange(of: draft.t3) { _ in testedSessions = nil }
        .onChange(of: draft.cmux) { _ in testedSessions = nil }
        .onChange(of: bridge.configuration) { configuration in
            if !hasUnsavedChanges {
                let editingLayerID = draft.selectedLayerID
                draft = configuration
                if configuration.layers.contains(where: { $0.id == editingLayerID }) {
                    draft.selectedLayerID = editingLayerID
                }
            }
            baseline = configuration
        }
        .task(id: workspaceLoader.requestID(for: draft)) {
            await workspaceLoader.load(draft, using: bridge)
        }
    }

    private var codexSection: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "keyboard.badge.ellipsis").font(.title2).foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Use Codex desktop buttons", isOn: $draft.reserveCodexSlots)
                        .font(.headline).toggleStyle(.switch)
                    Text(draft.reserveCodexSlots
                         ? "Reserves the first six shared agent slots for the Codex app. Keep its buttons on a separate layer in Input."
                         : "Agent slots are available to Micro Manager. Turn this on if you also use the Codex app's controller buttons.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if SessionConfiguration.codexInstalled {
                        Text("Codex is installed on this Mac.").font(.caption2).foregroundStyle(.secondary)
                    }
                    if draft.reserveCodexSlots != baseline.reserveCodexSlots {
                        Text("Apply each configured layer again after changing this setting.")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
        }
    }

    private var layerSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LAYERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(draft.layers) { layer in
                        Button { draft.selectedLayerID = layer.id } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: providerIcon(layer.provider)).frame(width: 16)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(layer.name.isEmpty ? layer.provider.title : layer.name)
                                        .font(.callout).fontWeight(.medium).lineLimit(1)
                                    Text(layer.provider.title).font(.caption).foregroundStyle(.secondary)
                                    Text(targetTitle(layer.target)).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(draft.selectedLayerID == layer.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Configure \(layer.name), \(layer.provider.title), \(targetTitle(layer.target))")
                    }
                }
                .padding(.horizontal, 8)
            }
            HStack {
                Menu {
                    ForEach(SessionProviderKind.allCases.filter { $0 != .demo }, id: \.self) { provider in
                        Button("Add \(provider.title) layer") { draft.addLayer(provider: provider) }
                    }
                } label: {
                    Label("Add layer", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                Spacer()
                Button { draft.removeLayer(id: draft.selectedLayerID) } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(draft.layers.count < 2 || selectedMappingApplied)
                .help(selectedMappingApplied ? "Restore this layer's buttons before removing it" : "Remove this layer configuration")
                .accessibilityLabel("Remove layer configuration")
            }
            .padding(14)
            Divider()
            Text("cmux, T3 and Herdr can share agent slots across separate layers. Micro Manager follows your hardware layer switches.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var layerHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Layer name", text: $draft.selectedLayer.name)
                    .textFieldStyle(.plain).font(.title2).bold()
                    .accessibilityLabel("Layer configuration name")
                if selectedMappingApplied {
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Text("Choose what this layer controls, then assign its keys.")
                .font(.caption).foregroundStyle(.secondary)
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
                } else if draft.provider == .cmux {
                    cmuxConnectionFields
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

    private var cmuxConnectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("cmux 0.64.22 or newer required", systemImage: "checkmark.shield")
                .font(.callout).fontWeight(.medium)
            Text("In cmux Settings → Automation, set Socket Control Mode to Automation mode so Micro Manager can connect. Older cmux versions must be updated.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Agent status setup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enable Claude Code Integration and Codex Integration in cmux Settings, then start new agent sessions. For a custom Codex launcher that bypasses cmux’s wrapper, run this once in a cmux terminal:")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("cmux hooks setup --agent codex")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("The Codex CLI integration reports terminal status. The Codex desktop buttons setting above reserves slots for the separate desktop app.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
            DisclosureGroup("Advanced connection settings") {
                VStack(spacing: 8) {
                    labeledField("cmux executable") {
                        TextField("/Applications/cmux.app/Contents/Resources/bin/cmux", text: $draft.cmux.cliPath)
                    }
                    labeledField("Socket path") {
                        TextField("Use the default cmux socket", text: $draft.cmux.socketPath)
                    }
                }
                .padding(.top, 8)
            }
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
                if bridge.availableLayers.isEmpty {
                    Text("Connect your Micro and read its layers, or enable the virtual pad from the menu.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Micro layer", selection: selectedDeviceLayerID) {
                        Text("Select a layer…").tag("")
                        ForEach(bridge.availableLayers) { layer in
                            Text(layer.title).tag(layer.id)
                                .disabled(targetIsUsedByAnotherLayer(layer.target))
                        }
                    }
                    .disabled(selectedMappingApplied)
                    if selectedMappingApplied {
                        Text("Restore buttons below before moving this configuration to another Micro layer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let target = draft.target, targetIsUsedByAnotherLayer(target) {
                    Label("This Micro layer is assigned to another provider. Choose a different layer.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
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
                        Text("Keep Wispr Flow on an unassigned key. Configure navigation and spare-button actions below.")
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
                if draft.provider == .t3 { actionButtonSection }
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
                                    Text(LayerMapping.agentCode(forPhysicalKey: key, slotOffset: draft.slotOffset) ?? "Unavailable")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                if draft.provider == .t3 {
                    Toggle("Use the dial and joystick down in T3", isOn: $draft.microControlsEnabled)
                        .toggleStyle(.checkbox)
                    if draft.microControlsEnabled {
                        Text("Joystick down toggles composer focus. In the composer, rotate to choose a setting and press to edit or confirm it. Outside the composer, rotate to scroll and press to jump to the latest message. T3 must be frontmost.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Apply replaces only dial rotation, dial press, and joystick down alongside your assigned buttons. Restore controls returns their saved bindings.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if draft.assignedButtonKeys.count > 16 - draft.slotOffset {
                            Text("Assign at most \(16 - draft.slotOffset) session and action buttons in total to leave room for these four controls.")
                                .font(.caption).foregroundStyle(.red)
                        }
                        if draft.provider != .t3 || draft.t3.openTarget != .desktop {
                            Text("Choose the T3 desktop connection to enable these controls.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Toggle("Use the ambient light for overall session status", isOn: $draft.driveAmbient)
                    .toggleStyle(.checkbox)
                Text("Apply backs up this layer before changing its selected keys and configured controls. Other configured layers keep their own provider and assignments.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(bridge.slotConflicts, id: \.self) { conflict in
                    Label(conflict, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let target = draft.target, let backup = bridge.backupPath(for: target) {
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
            Label("Micro layer & keys", systemImage: "keyboard").font(.headline)
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
                if draft.provider == .cmux {
                    CmuxViewSelector(
                        scope: draft.cmux.scope,
                        workspaceID: draft.cmux.workspaceID,
                        workspaces: workspaceLoader.workspaces,
                        isLoading: workspaceLoader.isLoading,
                        error: workspaceLoader.error,
                        onSelect: { scope, workspaceID in
                            draft.cmux.scope = scope
                            draft.cmux.workspaceID = workspaceID
                        },
                        onRefresh: { workspaceLoader.refresh() }
                    )
                    Divider()
                }
                Picker("Fill selected keys with", selection: $draft.selection) {
                    ForEach(SessionSelectionMode.available(for: draft.provider), id: \.self) { mode in
                        Text(mode.title(for: draft.provider)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(selectionDescription).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.selection.usesExplicitPins {
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
                        HStack {
                            Text("Load this view's sessions to choose pins.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Load sessions") { testConnection() }
                        }
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
                Text(hasUnsavedChanges ? "Unsaved settings" : "Settings saved")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save settings") { saveSettings(apply: false) }
                    .disabled(busy != nil || bridge.isBusy || draft.sessionKeys.isEmpty)
                Button("Save & apply this layer") { saveSettings(apply: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy != nil || bridge.isBusy || draft.target == nil || draft.sessionKeys.isEmpty)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var selectedLayer: DeviceLayer? {
        bridge.availableLayers.first { $0.target == draft.target }
    }

    private var hasUnsavedChanges: Bool {
        var settings = draft
        settings.selectedLayerID = baseline.selectedLayerID
        return settings != baseline
    }

    private var selectedMappingApplied: Bool {
        guard let target = draft.target else { return false }
        return bridge.hasAppliedMapping(for: target)
    }

    private func targetTitle(_ target: LayerTarget?) -> String {
        guard let target else { return "Choose a Micro layer" }
        return bridge.availableLayers.first(where: { $0.target == target })?.title
            ?? "Profile \(target.profileID), layer \(target.layerID)"
    }

    private func targetIsUsedByAnotherLayer(_ target: LayerTarget) -> Bool {
        draft.layers.contains { $0.id != draft.selectedLayerID && $0.target == target }
    }

    private func providerIcon(_ provider: SessionProviderKind) -> String {
        switch provider {
        case .t3: return "bubble.left.and.bubble.right"
        case .cmux: return "terminal"
        case .herdr: return "square.stack.3d.up"
        case .demo: return "play.rectangle"
        }
    }

    private var selectedDeviceLayerID: Binding<String> {
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
        case .providerOrder:
            return "Follow T3’s pinned and active sidebar order. Drag threads in T3 to rearrange your keys. Settled and snoozed threads are excluded. Uses all projects on this connection, regardless of sidebar filters."
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
            draft.controlBindings.removeAll { $0.inputID == key }
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
                await bridge.applyMapping(for: settings.selectedLayerID)
                try checkBridgeError()
                return "Layer applied. Enable Micro Manager and switch to this layer on your Micro."
            }
            return "Settings saved. Device bindings are changed with Apply."
        }
    }

    private func restoreMapping() {
        guard let target = draft.target else { return }
        run("Restoring button bindings…") {
            await bridge.restoreMapping(for: target)
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
