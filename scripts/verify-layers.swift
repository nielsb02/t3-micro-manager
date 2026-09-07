import Foundation
import Combine
@testable import WLKit

@MainActor final class LayerFixture: SessionControlProvider {
    let requiresEmulator = true
    let title: String
    var opened = 0
    var listed = 0
    var delay: UInt64 = 0
    var snapshot: [AgentSession]?
    var openedIDs: [String] = []
    var controls: [SessionControlAction] = []
    init(_ title: String) { self.title = title }
    func listSessions() async throws -> [AgentSession] {
        listed += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return snapshot ?? [AgentSession(id: "same-id", title: title, status: .done, completionID: "same-turn")]
    }
    func openSession(_ session: AgentSession) async throws { opened += 1; openedIDs.append(session.id) }
    func performControl(_ action: SessionControlAction, text: String) async throws { controls.append(action) }
    func executeCommand(_ text: String) async throws { throw SessionProviderError.unsupportedInput }
}

@main struct VerifyLayers {
    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.contains("micro-layers-verify.") == true)
        try configurationMigration()
        try providerSelectionAcrossLayers()
        try await routingAndBackups()
        try await combinedControlsAcrossLayers()
        try await inactiveLayerSelectionChange()
        try await interruptedMigration(retry: false)
        try await interruptedMigration(retry: true)
        try await pendingWriteRecovery()
        print("PASS: layer migration, scoped pins, continuous polling, first-press routing, slot sharing and interrupted mapping recovery")
    }

    static func providerSelectionAcrossLayers() throws {
        var settings = SessionConfiguration(reserveCodexSlots: true)
        settings.selection = .providerOrder
        let t3ID = settings.selectedLayerID
        let cmuxID = settings.addLayer(provider: .cmux)
        try settings.validate()
        precondition(settings.selection == .mixed && settings.cmux.scope == .workspaces)
        settings.selection = .providerOrder
        settings.selectedLayerID = t3ID
        do { try settings.validate(); preconditionFailure("Inactive cmux layer accepted T3-only ordering") }
        catch ConfigurationError.invalid {}
        settings.selectedLayerID = cmuxID; settings.selection = .recent
        settings.selectedLayerID = t3ID
        let restored = try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(settings))
        precondition(restored == settings && restored.selection == .providerOrder)
        print("T3 sidebar order survives alongside cmux recency; every layer validates its provider's modes.")
    }

    @MainActor static func combinedControlsAcrossLayers() async throws {
        var settings = SessionConfiguration(reserveCodexSlots: true)
        settings.target = LayerTarget(profileID: 0, layerID: 0)
        settings.sessionKeys = [0, 1]
        settings.actionButtons = [6: .newThread]
        settings.microControlsEnabled = true
        settings.selection = .providerOrder
        let t3ID = settings.selectedLayerID, t3Target = settings.target!
        settings.addLayer(provider: .cmux)
        settings.target = LayerTarget(profileID: 0, layerID: 1)
        settings.sessionKeys = [0, 1]
        settings.controlBindings = [.init(inputID: Pad.dialUpID, action: .nextTab), .init(inputID: 6, action: .submit)]
        let cmuxID = settings.selectedLayerID, cmuxTarget = settings.target!
        try settings.save()
        let t3 = LayerFixture("T3"), cmux = LayerFixture("cmux")
        t3.snapshot = [AgentSession(id: "t3", title: "T3", status: .working, providerOrder: 0)]
        let bridge = BridgeController(providerFactory: { $0.provider == .t3 ? t3 : cmux })
        await bridge.useEmulator(true)
        await bridge.applyMapping(for: t3ID)
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        await bridge.applyMapping(for: cmuxID)
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        let pad = bridge.emulator!
        try pad.activate(t3Target)
        await bridge.start()
        precondition(bridge.keymapReady && bridge.configuration.selection == .providerOrder)
        precondition(pad.slot(forPhysicalKey: 6) == 12 && pad.slot(forPhysicalKey: Pad.dialUpID) == 8)
        pad.press(0)
        try await eventually("T3 session routing with action buttons") { t3.opened == 1 }
        try pad.activate(cmuxTarget)
        pad.press(Pad.dialUpID)
        try await eventually("First dial event selects cmux instead of dispatching a T3 control") { cmux.controls == [.nextTab] }
        pad.press(6)
        try await eventually("The shared action button uses cmux's action") { cmux.controls == [.nextTab, .submit] }
        precondition(bridge.keymapReady && bridge.configuration.selectedLayerID == cmuxID)
        var unreserved = bridge.configuration
        unreserved.reserveCodexSlots = false
        await bridge.saveConfiguration(unreserved)
        await bridge.applyMapping(for: t3ID)
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        try pad.activate(t3Target)
        await bridge.start()
        await bridge.forceRepaint()
        precondition(bridge.keymapReady && pad.slot(forPhysicalKey: 0) == 0 && pad.slot(forPhysicalKey: Pad.dialUpID) == 2)
        await bridge.restoreMapping(for: t3Target)
        precondition(bridge.lastError == nil && pad.slot(forPhysicalKey: Pad.dialUpID) == nil)
        precondition(bridge.hasAppliedMapping(for: cmuxTarget))
        await bridge.restoreMapping(for: cmuxTarget)
        precondition(bridge.lastError == nil && !bridge.hasAppliedMapping(for: cmuxTarget))
        print("T3 actions + sidebar order coexist with cmux controls; shared slots, reservation changes and independent restore passed.")
    }

    static func configurationMigration() throws {
        let old = Data(#"{"provider":"t3","target":{"profileID":0,"layerID":0},"pinnedSessions":{"0":"saved-thread"}}"#.utf8)
        var settings = try JSONDecoder().decode(SessionConfiguration.self, from: old)
        precondition(settings.layers.count == 1 && settings.reserveCodexSlots)
        precondition(settings.pinnedSessions[0] == "saved-thread")
        let t3ID = settings.selectedLayerID
        settings.addLayer(provider: .cmux)
        let cmuxID = settings.selectedLayerID
        precondition(settings.cmux.scope == .workspaces && settings.pinnedSessions.isEmpty)
        settings.pinnedSessions[0] = "workspace-one"
        settings.cmux.scope = .workspace; settings.cmux.workspaceID = "workspace-one"
        precondition(settings.pinnedSessions.isEmpty)
        settings.pinnedSessions[0] = "terminal-one"
        settings.cmux.workspaceID = "workspace-two"
        precondition(settings.pinnedSessions.isEmpty)
        settings.cmux.workspaceID = "workspace-one"
        precondition(settings.pinnedSessions[0] == "terminal-one")
        settings.cmux.scope = .workspaces
        precondition(settings.pinnedSessions[0] == "workspace-one")
        settings.selectedLayerID = t3ID
        precondition(settings.pinnedSessions[0] == "saved-thread")
        let decoded = try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(settings))
        precondition(decoded == settings)
        settings.selectedLayerID = cmuxID; settings.target = LayerTarget(profileID: 0, layerID: 0)
        do { try settings.validate(); preconditionFailure("Duplicate hardware layer accepted") }
        catch ConfigurationError.invalid {}
        precondition(SessionConfiguration(reserveCodexSlots: false).slotOffset == 0)
        precondition(SessionConfiguration(reserveCodexSlots: true).slotOffset == 6)
        print("Single-layer settings migrate without changing slots; workspace and terminal pins remain independent.")
    }

    @MainActor static func routingAndBackups() async throws {
        var settings = SessionConfiguration(reserveCodexSlots: true)
        settings.target = LayerTarget(profileID: 0, layerID: 0)
        let firstID = settings.selectedLayerID
        let firstTarget = settings.target!
        settings.addLayer(provider: .herdr)
        settings.target = LayerTarget(profileID: 0, layerID: 1)
        let secondID = settings.selectedLayerID
        let secondTarget = settings.target!
        try settings.save()
        let first = LayerFixture("T3")
        let second = LayerFixture("Herdr")
        let bridge = BridgeController(providerFactory: { $0.provider == .t3 ? first : second })
        await bridge.useEmulator(true)
        await bridge.inspectDevice()
        await bridge.applyMapping(for: firstID)
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        await bridge.applyMapping(for: secondID)
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        precondition(bridge.hasAppliedMapping(for: firstTarget) && bridge.hasAppliedMapping(for: secondTarget))
        let pad = bridge.emulator!
        try pad.activate(firstTarget)
        await bridge.start()
        precondition(bridge.configuration.selectedLayerID == firstID && bridge.sessions.first?.title == "T3")
        precondition(pad.slot(forPhysicalKey: 0) == 6)
        let initialCalls = first.listed
        try await eventually("Startup must keep polling after selecting the physical layer") { first.listed > initialCalls }
        pad.press(0)
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(first.opened == 1 && bridge.sessions.first?.status == .idle)

        // The old layer is fetching when the first press arrives on an uncached layer.
        first.delay = 300_000_000
        let previousCalls = first.listed
        let oldRefresh = Task { await bridge.forceRepaint() }
        try await eventually("The old provider refresh must start") { first.listed > previousCalls }
        try pad.activate(secondTarget)
        pad.press(0)
        try await eventually("The first press must fetch and open the new layer") { second.opened == 1 }
        await oldRefresh.value
        first.delay = 0
        precondition(bridge.configuration.selectedLayerID == secondID)
        precondition(first.opened == 1 && second.opened == 1, "A shared slot must route using the actual layer")
        precondition(bridge.sessions.first?.title == "Herdr" && bridge.sessions.first?.status == .idle)
        try pad.activate(firstTarget)
        await bridge.forceRepaint()
        precondition(bridge.sessions.first?.status == .idle, "Layer switches must preserve completion acknowledgements")
        precondition((0...5).allSatisfy { pad.keys[$0] == nil }, "Reserved Codex slots must not be painted")

        var removed = bridge.configuration
        removed.removeLayer(id: secondID)
        await bridge.saveConfiguration(removed)
        precondition(bridge.lastError?.contains("Restore") == true && bridge.configuration.layers.count == 2)

        var unreserved = bridge.configuration
        unreserved.reserveCodexSlots = false
        await bridge.saveConfiguration(unreserved)
        precondition(!bridge.keymapReady, "A changed reservation needs explicit reapplication")
        await bridge.applyMapping(for: firstID)
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        precondition(pad.slot(forPhysicalKey: 0) == 0)
        pad.press(0)
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(first.opened == 2, "Unreserved AG00 must dispatch to the selected provider")

        await bridge.restoreMapping(for: secondTarget)
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        precondition(bridge.hasAppliedMapping(for: firstTarget) && !bridge.hasAppliedMapping(for: secondTarget))
        precondition(pad.slot(forPhysicalKey: 0) == 0, "Restoring another layer must preserve the active mapping")
        await bridge.restoreMapping(for: firstTarget)
        precondition(bridge.lastError == nil && !bridge.keymapReady)
        precondition(pad.bound.isEmpty)
        print("Two layers reuse slots and dispatch immediately; reservations migrate and each layer restores independently.")
    }

    @MainActor static func eventually(_ message: String, until predicate: () -> Bool) async throws {
        for _ in 0..<350 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure(message)
    }

    @MainActor static func inactiveLayerSelectionChange() async throws {
        var settings = SessionConfiguration(reserveCodexSlots: true)
        settings.target = LayerTarget(profileID: 0, layerID: 0)
        let firstID = settings.selectedLayerID
        let firstTarget = settings.target!
        settings.addLayer(provider: .herdr)
        settings.target = LayerTarget(profileID: 0, layerID: 1)
        let secondID = settings.selectedLayerID
        let secondTarget = settings.target!
        try settings.save()
        let first = LayerFixture("T3")
        first.snapshot = [
            AgentSession(id: "a", title: "Recent", status: .done, updatedAt: "2", completionID: "turn-a", providerOrder: 1),
            AgentSession(id: "b", title: "First in sidebar", status: .working, updatedAt: "1", providerOrder: 0)
        ]
        let second = LayerFixture("Herdr")
        let bridge = BridgeController(providerFactory: { $0.provider == .t3 ? first : second })
        await bridge.useEmulator(true)
        await bridge.applyMapping(for: firstID)
        await bridge.applyMapping(for: secondID)
        let pad = bridge.emulator!
        try pad.activate(firstTarget)
        await bridge.start()
        precondition(bridge.assignments[0] == "a")
        await bridge.focusSession(bridge.sessions.first { $0.id == "a" }!)
        try pad.activate(secondTarget)
        await bridge.forceRepaint()
        var changed = bridge.configuration
        changed.layers[0].selection = .providerOrder
        await bridge.saveConfiguration(changed)
        precondition(bridge.lastError == nil && bridge.configuration.selectedLayerID == secondID)
        try pad.activate(firstTarget)
        pad.press(0)
        try await eventually("The first press must use the inactive layer's newly saved assignment mode") { first.openedIDs.count == 2 }
        precondition(first.openedIDs == ["a", "b"], "Saved sidebar order must replace cached recent assignments")
        precondition(bridge.sessions.first { $0.id == "a" }?.status == .idle, "Refreshing assignments must preserve completion acknowledgements")
        await bridge.restoreMapping(for: firstTarget)
        await bridge.restoreMapping(for: secondTarget)
        precondition(bridge.lastError == nil)
        print("Editing an inactive layer refreshes its first press without losing completion acknowledgements.")
    }

    @MainActor static func rawMapping(_ pad: PadEmulator) throws -> [String: Any] {
        let response = pad.handle("fs.read", params: ["file": "keymap.json"])
        let text = (response.result as! [String: Any])["data"] as! String
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    @MainActor static func write(_ config: [String: Any], to pad: PadEmulator) throws {
        let data = try JSONSerialization.data(withJSONObject: config)
        let response = pad.handle("fs.write", params: ["file": "keymap.json", "data": String(decoding: data, as: UTF8.self)])
        precondition(response.error == nil)
    }

    static func replacing(_ config: [String: Any], target: LayerTarget, key: Int, with code: String) -> [String: Any] {
        var result = config
        var profiles = result["profiles"] as! [[String: Any]]
        let profile = profiles.firstIndex { $0["id"] as? Int == target.profileID }!
        var layers = profiles[profile]["layers"] as! [[String: Any]]
        let layer = layers.firstIndex { $0["id"] as? Int == target.layerID }!
        var layout = layers[layer]["layout"] as! [String: Any]
        var keys = layout["keymap"] as! [[String]]
        let position = Pad.position(of: key)!
        keys[position.row][position.column] = code
        layout["keymap"] = keys; layers[layer]["layout"] = layout
        profiles[profile]["layers"] = layers; result["profiles"] = profiles
        return result
    }

    @MainActor static func interruptedMigration(retry: Bool) async throws {
        var settings = SessionConfiguration(reserveCodexSlots: true)
        settings.target = LayerTarget(profileID: 0, layerID: 0)
        settings.sessionKeys = [0, 1]
        let firstID = settings.selectedLayerID
        let firstTarget = settings.target!
        settings.addLayer(provider: .herdr)
        settings.target = LayerTarget(profileID: 0, layerID: 1)
        let secondID = settings.selectedLayerID
        let secondTarget = settings.target!
        try settings.save()
        let bridge = BridgeController(providerFactory: { _ in LayerFixture("Recovery") })
        await bridge.useEmulator(true)
        await bridge.applyMapping(for: firstID)
        await bridge.applyMapping(for: secondID)
        precondition(bridge.lastError == nil, bridge.lastError ?? "")
        settings.reserveCodexSlots = false
        settings.selectedLayerID = firstID
        await bridge.saveConfiguration(settings)
        let pad = bridge.emulator!
        try pad.activate(firstTarget)
        let inputEdit = replacing(try rawMapping(pad), target: firstTarget, key: 1, with: "KC_X")
        var editScheduled = false
        let observation = pad.$traffic.dropFirst().sink { lines in
            guard !editScheduled, lines.last == "fs.read keymap.json" else { return }
            editScheduled = true
            DispatchQueue.main.async { try! write(inputEdit, to: pad) }
        }
        await bridge.applyMapping(for: firstID)
        observation.cancel()
        precondition(editScheduled && bridge.lastError?.contains("changed in Input") == true,
                     "The fixture must reject migration after the concurrent Input edit: \(bridge.lastError ?? "none")")
        precondition(pad.slot(forPhysicalKey: 0) == 6 && !bridge.keymapReady)

        if retry {
            await bridge.applyMapping(for: firstID)
            precondition(bridge.lastError == nil && pad.slot(forPhysicalKey: 0) == 0)
            await bridge.restoreMapping(for: firstTarget)
            precondition(bridge.lastError == nil, bridge.lastError ?? "")
            precondition(pad.layers.first { $0.target == firstTarget }!.keymap[0] == ["KC_F13", "KC_X"],
                         "Retry must retain the actual shortcuts, including the later Input edit")
            await bridge.restoreMapping(for: secondTarget)
            precondition(bridge.lastError == nil)
        } else {
            let persistedDeviceMap = try rawMapping(pad)
            let restarted = BridgeController(providerFactory: { _ in LayerFixture("Restart") })
            await restarted.useEmulator(true)
            let restartedPad = restarted.emulator!
            try write(persistedDeviceMap, to: restartedPad)
            await restarted.inspectDevice()
            precondition(!restarted.keymapReady)
            await restarted.restoreMapping(for: firstTarget)
            precondition(restarted.lastError == nil, restarted.lastError ?? "")
            precondition(restartedPad.layers.first { $0.target == firstTarget }!.keymap[0] == ["KC_F13", "KC_X"])
            precondition(restarted.hasAppliedMapping(for: secondTarget))
            let remaining = try rawMapping(restartedPad)
            precondition(LayerMapping.isApplied(config: remaining, target: secondTarget, keys: settings.layers[1].sessionKeys))
            await restarted.restoreMapping(for: secondTarget)
            precondition(restarted.lastError == nil)
        }
        print("Rejected slot migration preserves originals for \(retry ? "retry and Restore" : "restart and Restore"), later Input edits and other layers.")
    }

    @MainActor static func pendingWriteRecovery() async throws {
        var settings = SessionConfiguration(reserveCodexSlots: true)
        settings.target = LayerTarget(profileID: 0, layerID: 0)
        settings.sessionKeys = [0, 1]
        try settings.save()
        let bridge = BridgeController(providerFactory: { _ in LayerFixture("Pending") })
        await bridge.useEmulator(true)
        await bridge.applyMapping()
        precondition(bridge.lastError == nil)
        let pad = bridge.emulator!
        let oldMap = try rawMapping(pad)
        let recordURL = SessionConfiguration.fileURL.deletingLastPathComponent().appendingPathComponent("emulator-mapping-backup.json")
        let originalArchive = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: Any]
        let originalRecord = (originalArchive["records"] as! [[String: Any]])[0]
        let originalBackup = try JSONDecoder().decode(LayerMapping.Backup.self, from: JSONSerialization.data(withJSONObject: originalRecord["backup"]!))
        let restored = try LayerMapping.restoring(config: oldMap, backup: originalBackup)
        let pending = try LayerMapping.capture(config: restored, target: settings.target!, keys: [0, 1], slotOffset: 0)
        var record = originalRecord
        record["backup"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending))
        record["previousBackups"] = [originalRecord["backup"]!]
        try JSONSerialization.data(withJSONObject: ["records": [record]]).write(to: recordURL, options: .atomic)
        var written = try LayerMapping.applying(config: restored, target: settings.target!, keys: [0, 1], slotOffset: 0)
        written = replacing(written, target: settings.target!, key: 1, with: "KC_Y")
        let restarted = BridgeController(providerFactory: { _ in LayerFixture("After write") })
        await restarted.useEmulator(true)
        try write(written, to: restarted.emulator!)
        await restarted.inspectDevice()
        await restarted.restoreMapping()
        precondition(restarted.lastError == nil, restarted.lastError ?? "")
        precondition(restarted.emulator!.layers[0].keymap[0] == ["KC_F13", "KC_Y"],
                     "A crash after the write must restore pending ownership and preserve later Input edits")

        // The pre-layer, single-record recovery format remains readable.
        try JSONSerialization.data(withJSONObject: originalRecord).write(to: recordURL, options: .atomic)
        try write(oldMap, to: restarted.emulator!)
        await restarted.inspectDevice()
        await restarted.restoreMapping()
        precondition(restarted.lastError == nil && restarted.emulator!.layers[0].keymap[0] == ["KC_F13", "KC_F14"])
        print("Pending post-write ownership and legacy single-record backups survive restart and restore correctly.")
    }
}
