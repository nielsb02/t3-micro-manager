import Foundation
@testable import WLKit

@MainActor final class ControlFixture: SessionControlProvider {
    let requiresEmulator = true
    var actions: [SessionControlAction] = []
    var texts: [String] = []
    var delay: UInt64 = 0
    var started = 0
    var canceled = 0
    func listSessions() async throws -> [AgentSession] { [.init(id: "one", title: "One", status: .idle)] }
    func openSession(_ session: AgentSession) async throws {}
    func performControl(_ action: SessionControlAction, text: String) async throws {
        started += 1
        do { if delay > 0 { try await Task.sleep(nanoseconds: delay) } }
        catch { canceled += 1; throw error }
        actions.append(action); texts.append(text)
    }
    func executeCommand(_ text: String) async throws { texts.append(text) }
}

@main struct VerifyControls {
    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.contains("micro-controls-verify.") == true)
        let keys = Pad.agentKeyIDs
        let controls = SessionControlBinding.navigationPreset.map(\.inputID)
        let slots = try LayerMapping.slotAssignments(keys: keys, controls: controls, slotOffset: 6)
        precondition(slots.count == 14 && Set(slots.values) == Set(6...19))
        let reordered = try LayerMapping.slotAssignments(keys: keys, controls: controls.reversed(), slotOffset: 6)
        precondition(reordered == slots)
        do { _ = try LayerMapping.slotAssignments(keys: keys, controls: controls + [8]); preconditionFailure("Over-allocation accepted") }
        catch LayerMapping.Failure.invalidControls {}
        do { _ = try LayerMapping.slotAssignments(keys: keys, controls: controls + [0]); preconditionFailure("A session key also got a control") }
        catch LayerMapping.Failure.invalidControls {}
        let original = PadEmulator.stockKeymap()
        let target = LayerTarget(profileID: 0, layerID: 0)
        let backup = try LayerMapping.capture(config: original, target: target, keys: keys, controls: controls)
        var mapped = try LayerMapping.applying(config: original, target: target, keys: keys, controls: controls)
        precondition(LayerMapping.isApplied(config: mapped, target: target, keys: keys, controls: controls))
        let restored = try LayerMapping.restoring(config: mapped, backup: backup)
        precondition(NSDictionary(dictionary: restored).isEqual(to: original), "Restore must cover keys, dial and cardinal sectors")
        var profiles = mapped["profiles"] as! [[String: Any]]
        var layers = profiles[0]["layers"] as! [[String: Any]]
        var layout = layers[0]["layout"] as! [String: Any]
        var encoders = layout["encoders"] as! [[String]]
        encoders[0][0] = "KC_F1"; layout["encoders"] = encoders
        layers[0]["layout"] = layout; profiles[0]["layers"] = layers; mapped["profiles"] = profiles
        let afterEdit = try LayerMapping.restoring(config: mapped, backup: backup)
        let editedProfiles = afterEdit["profiles"] as! [[String: Any]]
        let editedLayers = editedProfiles[0]["layers"] as! [[String: Any]]
        let editedLayout = editedLayers[0]["layout"] as! [String: Any]
        precondition((editedLayout["encoders"] as! [[String]])[0][0] == "KC_F1", "Later Input edits must survive restore")
        do { _ = try LayerMapping.applying(config: original, target: .init(profileID: 0, layerID: 1), keys: keys, controls: controls); preconditionFailure("Missing joystick sectors accepted") }
        catch LayerMapping.Failure.invalidControls {}
        print("Control allocation, capacity, ordering, dial/joystick backup and restoration passed.")

        var settings = SessionConfiguration(reserveCodexSlots: true)
        settings.provider = .cmux; settings.target = target; settings.controlBindings = SessionControlBinding.navigationPreset
        try settings.save()
        let decoded = try SessionConfiguration.load()
        precondition(decoded.controlBindings == settings.controlBindings)
        let provider = ControlFixture()
        let bridge = BridgeController(providerFactory: { _ in provider })
        await bridge.useEmulator(true); await bridge.inspectDevice(); await bridge.applyMapping()
        precondition(bridge.lastError == nil && bridge.keymapReady, bridge.lastError ?? "Mapping not ready")
        await bridge.start()
        let pad = bridge.emulator!
        precondition(pad.slot(forPhysicalKey: Pad.dialPressID) == slots[Pad.dialPressID])
        pad.press(Pad.dialUpID); pad.press(Pad.joyNorthID); pad.press(7)
        try await eventually { provider.actions.count == 3 }
        precondition(provider.actions == [.nextTab, .focusUp, .submit], "Input events must execute in order")
        pad.press(Pad.dialPressID)
        try await eventually { bridge.dialControlsWorkspaces }
        pad.press(Pad.dialDownID)
        try await eventually { provider.actions.count == 4 }
        precondition(provider.actions.last == .previousWorkspace)
        var overrides = 0
        bridge.onControlOverride = { action in if action == .submit { overrides += 1; return true }; return false }
        pad.press(7); try await eventually { overrides == 1 }
        precondition(provider.actions.count == 4, "Command-panel submit must not also submit a terminal")
        provider.delay = 3_000_000_000
        let started = provider.started
        pad.press(Pad.dialUpID); pad.press(Pad.dialDownID)
        try await eventually { provider.started > started }
        await bridge.stop()
        precondition(provider.canceled == 1 && provider.actions.count == 4, "Stop must cancel the running control and drain queued controls")
        pad.press(Pad.dialUpID)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(provider.actions.count == 4)
        await bridge.restoreMapping(for: target)
        precondition(pad.slot(forPhysicalKey: Pad.dialUpID) == nil && pad.slot(forPhysicalKey: Pad.joyNorthID) == nil)
        print("Emulated HID routing, dial mode, queued controls, panel submit interception, stop and restore passed.")
    }
    @MainActor static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure("Control did not reach its destination")
    }
}
