import Foundation
@testable import WLKit

@main struct VerifyBridge {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--check-t3") {
            let settings = try SessionConfiguration.load()
            let client = T3Client(settings: settings.t3)
            let sessions = try await client.listSessions()
            for session in sessions { _ = try client.sessionURL(session) }
            print("Swift T3 client verified \(sessions.count) live session summaries and their exact URLs.")
            return
        }
        if CommandLine.arguments.contains("--inspect-device") {
            let device = WLDevice()
            do { try device.connect() } catch {
                print("Read-only device inspection could not open the pad: \(error.localizedDescription)")
                exit(2)
            }
            defer { device.disconnect(reason: nil) }
            let config = try await KeymapManager.read(device)
            let layers = try LayerMapping.layers(in: config)
            let status = try await device.callAsync("device.status") as? [String: Any] ?? [:]
            print("Device: \(device.info?.product ?? "unknown")")
            for layer in layers {
                let active = LayerMapping.isActive(status: status, config: config, target: layer.target)
                let keys = layer.keymap.flatMap { $0 }
                print("\(layer.title) [profile \(layer.target.profileID), layer \(layer.target.layerID)] active=\(active)")
                print("  Session positions: \(keys.prefix(6).joined(separator: ", "))")
                print("  Microphone positions: \(keys.dropFirst(10).prefix(2).joined(separator: ", "))")
            }
            print("Read-only device inspection passed; no writes.")
            return
        }
        precondition(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.contains("micro-verify") == true,
                     "Run through scripts/verify-bridge.sh to isolate configuration.")
        var cfg = SessionConfiguration(reserveCodexSlots: true)
        cfg.sessionKeys = [1, 0]
        let sessions = [
            AgentSession(id: "active", title: "Active", status: .working, updatedAt: "1"),
            AgentSession(id: "recent", title: "Recent", status: .done, updatedAt: "3"),
            AgentSession(id: "pin", title: "Pinned", status: .idle, updatedAt: "2", isPinned: true)
        ]
        cfg.selection = .recent
        precondition(SessionAssignments.assign(sessions, configuration: cfg) == [1:"recent", 0:"pin"])
        precondition(SessionAssignments.assign(sessions, configuration: cfg, previous: [1:"active"]) == [1:"active", 0:"recent"])
        cfg.selection = .mixed
        precondition(SessionAssignments.assign(sessions, configuration: cfg) == [1:"pin", 0:"recent"])
        cfg.pinnedSessions = [1:"missing"]
        precondition(SessionAssignments.assign(sessions, configuration: cfg)[1] == nil)
        cfg.selection = .pinned
        precondition(SessionAssignments.assign(sessions, configuration: cfg) == [0:"pin"])
        cfg.pinnedSessions = [1:"pin", 0:"pin"]
        precondition(SessionAssignments.assign(sessions, configuration: cfg).count == 1)
        print("Session assignment checks passed.")

        cfg.selection = .providerOrder
        let arranged = [
            AgentSession(id: "first", title: "First", status: .working, providerOrder: 0),
            AgentSession(id: "second", title: "Second", status: .blocked, providerOrder: 1),
            AgentSession(id: "history", title: "History", status: .done)
        ]
        precondition(SessionAssignments.assign(Array(arranged.reversed()), configuration: cfg, previous: [1: "second", 0: "first"])
                     == [1: "first", 0: "second"], "App order overrides old working slots and local pins")
        var moved = arranged
        moved[0].providerOrder = 1; moved[1].providerOrder = 0
        precondition(SessionAssignments.assign(moved, configuration: cfg, previous: [1: "first", 0: "second"])
                     == [1: "second", 0: "first"], "Provider drag order must reach physical key assignments")
        moved[1].providerOrder = nil
        precondition(SessionAssignments.assign(moved, configuration: cfg) == [1: "first"],
                     "Settled sessions must not fill spare keys")
        let restored = try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(cfg))
        precondition(restored == cfg)
        print("App ordering, live rearrangement, excluded history and configuration round-trip passed.")

        try SessionConfiguration(reserveCodexSlots: true).save()
        let bridge = BridgeController()
        await bridge.startDemo()
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        precondition(bridge.isRunning && bridge.keymapReady && bridge.layerActive)
        let pad = bridge.emulator!
        precondition(pad.bound == Set([6,7,8,9,10,11]))
        precondition(pad.keys[7]?.isLit == true)
        precondition(pad.ambientZone == .dark)
        precondition((0...5).allSatisfy { pad.keys[$0] == nil }, "T3 must not write Codex slots")
        _ = pad.handle(OAI.methodThreads, params: [["id": 0, "c": 0x123456, "b": 1, "e": 1]])
        let codexLight = pad.keys[0]
        for _ in 0..<12 {
            if bridge.sessions.first(where: { $0.id == "demo-build" })?.status == .done { break }
            await bridge.forceRepaint()
        }
        precondition(Pad.displayRows[0] == [0, 1])
        precondition(bridge.assignments[Pad.displayRows[0][0]] == "demo-build")
        precondition(bridge.sessions.first(where: { $0.id == "demo-build" })?.status == .done)
        let notificationHandler = pad.onNotify
        var pressSlots: [Int] = []
        pad.onNotify = { method, payload in
            if let value = payload as? [String: Any], value["act"] as? Int == 1,
               let slot = OAI.agIndex(value["k"] as? String) { pressSlots.append(slot) }
            notificationHandler?(method, payload)
        }
        pad.press(0)
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(pressSlots == [6], "Physical top-left key must emit AG06, outside Codex's handler")
        precondition(bridge.sessions.first(where: { $0.id == "demo-build" })?.status == .idle,
                     "Bridge must route AG06 to the session shown at the top-left screen position")
        precondition(pad.keys[0] == codexLight)
        print("Press routing uses separate AG slots and preserves Codex lighting.")
        let trafficCount = pad.traffic.count
        let untouched = pad.layers[1].target
        try pad.activate(untouched)
        await bridge.forceRepaint()
        precondition(!bridge.layerActive)
        let subsequent = pad.traffic.dropFirst(trafficCount)
        precondition(!subsequent.contains(where: { $0.contains("thstatus") || $0.contains("rgbcfg") }))
        await bridge.stop()
        precondition(pad.keys[0] == codexLight, "Stopping must not clear Codex slots")
        let target = bridge.configuration.target!
        try pad.activate(target)
        await bridge.restoreMapping()
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        precondition(pad.bound.isEmpty && !bridge.keymapReady)
        print("Emulator bridge, layer gating, selective lighting and restoration passed.")

        // Pre-existing AG bindings do not authorize ownership on a newly selected layer.
        let device = WLDevice(emulator: pad)
        try device.connect()
        let raw = try await KeymapManager.read(device)
        let bound = try LayerMapping.applying(config: raw, target: untouched, keys: [1,0])
        let data = try JSONSerialization.data(withJSONObject: bound)
        _ = try await device.callAsync("fs.write", params: ["file":"keymap.json", "data":String(decoding:data,as:UTF8.self)])
        var newConfig = bridge.configuration
        newConfig.target = untouched; newConfig.sessionKeys = [1,0]
        await bridge.saveConfiguration(newConfig)
        try pad.activate(untouched)
        await bridge.start()
        precondition(!bridge.keymapReady)
        await bridge.stop()
        print("Unclaimed layer protection passed.")
        await bridge.applyMapping()
        precondition(bridge.keymapReady)
        await bridge.restoreMapping()
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        precondition(!bridge.keymapReady && bridge.backupPath == nil)
        print("Restoring adopted AG bindings relinquishes ownership.")
    }
}
