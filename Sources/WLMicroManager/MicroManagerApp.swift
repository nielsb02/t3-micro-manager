import SwiftUI
import AppKit
import ServiceManagement
import WLKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app-switcher entry. The bundled app
        // also sets LSUIElement; this covers `swift run` during development.
        NSApplication.shared.setActivationPolicy(.accessory)
        // Used after moving an installation whose login item was already enabled.
        if CommandLine.arguments.contains("--refresh-login-item"), SMAppService.mainApp.status == .enabled {
            do {
                try SMAppService.mainApp.unregister()
                try SMAppService.mainApp.register()
            } catch {
                NSLog("Could not update Micro Manager's login item: %@", error.localizedDescription)
            }
        }
    }
}

@main
struct MicroManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var bridge = BridgeController()
    @State private var initialized = false

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(bridge)

        } label: {
            Image(nsImage: MenuBarIcon.image(for: MenuBarIcon.State.from(bridge)))
                .task {
                    guard !initialized else { return }
                    initialized = true
                    // Choose the transport before starting: `useEmulator`
                    // rebuilds the device, so doing it after would tear down a
                    // connection we just made.
                    await bridge.useEmulator(BridgeSettings.emulate)

                    // Come back up in whatever state it was left in, so a
                    // login-item launch resumes rather than sitting idle.
                    // First launch opens configuration without touching hardware.
                    if CommandLine.arguments.contains("--configure") {
                        await bridge.inspectDevice()
                        ConfigurationWindowController.shared.show(bridge)
                    } else if BridgeSettings.enabled, !bridge.isRunning {
                        await bridge.start()
                    } else if bridge.configuration.target == nil {
                        ConfigurationWindowController.shared.show(bridge)
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Persisted across launches.
enum BridgeSettings {
    private static let key = "bridgeEnabled"

    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return false }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static let emulateKey = "emulatePad"

    /// Drive a virtual pad instead of the hardware. `WL_EMULATE=1` forces it on
    /// for a single run, which is what makes `swift run` useful with no device
    /// plugged in.
    static var emulate: Bool {
        get {
            if ProcessInfo.processInfo.environment["WL_EMULATE"] == "1" { return true }
            return UserDefaults.standard.bool(forKey: emulateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: emulateKey) }
    }
}
