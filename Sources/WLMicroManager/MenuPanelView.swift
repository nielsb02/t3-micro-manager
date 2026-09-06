import AppKit
import ServiceManagement
import SwiftUI
import WLKit

struct MenuPanelView: View {
    @EnvironmentObject var bridge: BridgeController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var inspectorError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if bridge.permissionDenied {
                permissionBanner
            } else {
                padSection
                if bridge.isRunning {
                    Divider()
                    sessionSection
                }
            }
            if let error = bridge.lastError, !bridge.permissionDenied {
                message(error, color: .red)
            }
            if bridge.contendingClient {
                message("Another app is communicating with this pad. If lights flicker, pause its lighting integration.", color: .orange)
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Micro Manager").font(.headline)
                Text(bridge.configuration.provider.title + " · " + subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("Enable Micro Manager", isOn: Binding(
                get: { bridge.isRunning },
                set: { on in
                    BridgeSettings.enabled = on
                    Task { await bridge.toggle() }
                }
            ))
            .toggleStyle(.switch).labelsHidden()
            .help(bridge.isRunning ? "Turn off" : "Turn on")
        }
        .padding(14)
        .disabled(bridge.isBusy)
    }

    private var subtitle: String {
        guard bridge.isRunning else { return "Off" }
        guard bridge.deviceConnected else { return "Looking for your Micro…" }
        guard bridge.configuration.target != nil else { return "Choose a layer" }
        guard bridge.keymapReady else { return "Configure session keys" }
        return bridge.layerActive ? "Connected" : "Waiting for your layer"
    }

    private var padSection: some View {
        HStack(alignment: .center, spacing: 18) {
            SessionKeyGrid(
                selected: Set(bridge.configuration.sessionKeys),
                colors: bridge.keyColors,
                keyWidth: 31,
                keyHeight: 24,
                onPress: { bridge.handleKeyPress($0) }
            )
            VStack(alignment: .leading, spacing: 6) {
                if bridge.deviceConnected {
                    Text(bridge.deviceName).font(.caption).lineLimit(2)
                    if let battery = bridge.battery {
                        Text(battery).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach([SessionStatus.blocked, .working, .done, .idle, .error], id: \.self) { status in
                    Label(sessionStatusLabel(status), systemImage: "circle.fill")
                        .foregroundStyle(sessionColor(status))
                }
            }
            .font(.system(size: 10))
        }
        .padding(14)
        .disabled(bridge.isBusy)
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(bridge.configuration.selection.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(bridge.sessions.count) sessions").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 5)
            if bridge.sessions.isEmpty {
                Text("No sessions yet. Check the connection in Configure.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(bridge.sessions) { session in
                            Button {
                                Task { await bridge.focusSession(session) }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(sessionColor(session.status)).frame(width: 8, height: 8)
                                    Text(session.title).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if let key = bridge.configuration.sessionKeys.first(where: { bridge.assignments[$0] == session.id }) {
                                        Text("\(key)")
                                            .font(.system(.caption2, design: .monospaced))
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                    }
                                    Text(sessionStatusLabel(session.status))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle()).padding(.horizontal, 14).padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .help("Open this session in \(bridge.configuration.provider.title)")
                        }
                    }
                }
                .frame(height: min(CGFloat(bridge.sessions.count) * 30, 210))
                .padding(.bottom, 7)
            }
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Monitoring is needed", systemImage: "lock.fill").font(.callout).bold()
            Text("Allow Micro Manager to monitor input so it can receive presses from your Micro.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(14)
        .disabled(bridge.isBusy)
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button("Configure…") { ConfigurationWindowController.shared.show(bridge) }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Refresh") { Task { await bridge.forceRepaint() } }
                    .disabled(!bridge.isRunning || bridge.isBusy)
            }
            Toggle("Open at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                        inspectorError = error.localizedDescription
                    }
                }
            Toggle("Emulate the pad", isOn: Binding(
                get: { bridge.emulator != nil },
                set: { on in
                    BridgeSettings.emulate = on
                    Task {
                        await bridge.useEmulator(on)
                        if let emulator = bridge.emulator {
                            EmulatorWindowController.shared.show(emulator)
                        } else {
                            EmulatorWindowController.shared.close()
                        }
                    }
                }
            ))
            .toggleStyle(.checkbox)
            HStack {
                Button("Try demo") {
                    Task {
                        BridgeSettings.emulate = true
                        await bridge.startDemo()
                        if let emulator = bridge.emulator {
                            EmulatorWindowController.shared.show(emulator)
                        }
                    }
                }
                .help("Show sample sessions on a virtual Micro")
                Button("Inspector") {
                    inspectorError = nil
                    InspectorLauncher.launch { inspectorError = $0 }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            if let inspectorError {
                Text(inspectorError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .disabled(bridge.isBusy)
    }
}

func sessionStatusLabel(_ status: SessionStatus) -> String { status.title }

func sessionColor(_ status: SessionStatus) -> Color {
    Color(packedRGB: SessionAppearance(status: status).color)
}
