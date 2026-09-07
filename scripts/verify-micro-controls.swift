import Foundation
@testable import WLKit

@main struct VerifyMicroControls {
    static func check(_ value: Bool, _ message: String = "Micro control verification failed") { precondition(value, message) }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Accepted invalid mapping or reply") } catch { }
    }
    static func encoded(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }
    static func editLayout(_ config: [String: Any], _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var result = config
        var profiles = config["profiles"] as! [[String: Any]]
        var layers = profiles[0]["layers"] as! [[String: Any]]
        var layout = layers[0]["layout"] as! [String: Any]
        edit(&layout)
        layers[0]["layout"] = layout
        profiles[0]["layers"] = layers
        result["profiles"] = profiles
        return result
    }

    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.contains("micro-controls") == true,
                     "Run through scripts/verify-micro-controls.sh to isolate configuration.")
        let legacy = try JSONDecoder().decode(SessionConfiguration.self, from: Data(#"{"sessionKeys":[0,1,4]}"#.utf8))
        check(!legacy.microControlsEnabled && legacy.sessionKeys == [0, 1, 4])
        check(legacy.actionButtons.isEmpty)
        try await verifyActionButtons()
        var configuration = legacy
        configuration.microControlsEnabled = true
        try configuration.validate()
        configuration.sessionKeys = Array(0...10)
        rejects { try configuration.validate() }
        configuration.sessionKeys = [0]
        configuration.t3.openTarget = .browser
        rejects { try configuration.validate() }

        let target = LayerTarget(profileID: 0, layerID: 0)
        let stock = PadEmulator.stockKeymap()
        let slots = try MicroControlMapping.slots(config: stock, target: target, sessionKeys: [0, 1])
        check(slots == [.dialClockwise: 8, .dialCounterclockwise: 9, .dialPress: 10, .composerToggle: 11])
        check(try MicroControlMapping.slots(config: stock, target: target, sessionKeys: [1, 0]) == slots)
        let full = try MicroControlMapping.slots(config: stock, target: target, sessionKeys: Array(0...9))
        check(Set(full.values) == Set(16...19))
        rejects { _ = try LayerMapping.applying(config: stock, target: target, keys: Array(0...10), controlsEnabled: true) }
        let crowded = editLayout(stock) { $0["other"] = (7...17).map { String(format: "KV_OAI_AG%02d", $0) } }
        rejects { _ = try LayerMapping.applying(config: crowded, target: target, keys: [0], controlsEnabled: true) }
        let conflict = editLayout(stock) { $0["other"] = "KV_OAI_AG06" }
        rejects { _ = try LayerMapping.applying(config: conflict, target: target, keys: [0], controlsEnabled: true) }
        let occupied = editLayout(stock) { $0["other"] = ["KV_OAI_AG08", "KV_OAI_AG05"] }
        check(try MicroControlMapping.slots(config: occupied, target: target, sessionKeys: [0, 1]) == [
            .dialClockwise: 9, .dialCounterclockwise: 10, .dialPress: 11, .composerToggle: 12])
        let missing = editLayout(stock) { $0["encoders"] = [["KC_VOLU", "KC_VOLD"]] }
        rejects { _ = try LayerMapping.applying(config: missing, target: target, keys: [0], controlsEnabled: true) }
        print("PASS: legacy opt-out, deterministic free slots, firmware limit, collisions and missing controls")

        let backup = try LayerMapping.capture(config: stock, target: target, keys: [0, 1], controlsEnabled: true)
        let decoded = try JSONDecoder().decode(LayerMapping.Backup.self, from: JSONEncoder().encode(backup))
        check(decoded == backup)
        let applied = try LayerMapping.applying(config: stock, target: target, keys: [0, 1], controlsEnabled: true)
        check(LayerMapping.isApplied(config: applied, target: target, keys: [0, 1], controlsEnabled: true))
        check(try encoded(applied) == encoded(LayerMapping.applying(config: applied, target: target, keys: [0, 1], controlsEnabled: true)))
        let expected = editLayout(stock) { layout in
            var matrix = layout["keymap"] as! [[String]]
            matrix[0] = ["KV_OAI_AG06", "KV_OAI_AG07"]
            layout["keymap"] = matrix
            layout["encoders"] = [["KV_OAI_AG08", "KV_OAI_AG09", "KV_OAI_AG10"]]
            var joystick = layout["joystick"] as! [String: Any]
            var sectors = joystick["sectors"] as! [[String: Any]]
            sectors[4]["k"] = "KV_OAI_AG11"
            joystick["sectors"] = sectors
            layout["joystick"] = joystick
        }
        check(try encoded(applied) == encoded(expected), "Mapping changed an unselected key, microphone, joystick sector or layer")
        let restored = try LayerMapping.restoring(config: applied, backup: decoded)
        check(try encoded(restored) == encoded(stock))
        let edited = editLayout(applied) { $0["encoders"] = [["KC_PLUS", "KV_OAI_AG09", "KC_MUTE"]] }
        let expectedEdited = editLayout(stock) { $0["encoders"] = [["KC_PLUS", "KC_VOLD", "KC_MUTE"]] }
        let restoredEdited = try LayerMapping.restoring(config: edited, backup: decoded)
        check(try encoded(restoredEdited) == encoded(expectedEdited))
        check(try encoded(LayerMapping.restoring(config: restoredEdited, backup: decoded)) == encoded(restoredEdited))
        let nextBackup = try LayerMapping.capture(config: restored, target: target, keys: [2, 3], controlsEnabled: true)
        let next = try LayerMapping.applying(config: restored, target: target, keys: [2, 3], controlsEnabled: true)
        check(try encoded(LayerMapping.restoring(config: next, backup: nextBackup)) == encoded(stock))
        check(try encoded(LayerMapping.applying(config: restored, target: target, keys: [0, 1])) == encoded(LayerMapping.applying(config: stock, target: target, keys: [0, 1])))
        check(MicroControlMapping.input(slot: 8, sessionKeys: [0, 1, 2], controls: slots) == .control(.dialClockwise))
        check(MicroControlMapping.input(slot: 6, sessionKeys: [0, 1], controls: slots) == .sessionKey(0))
        print("PASS: exact backup restoration, later Input edits, reallocating/disabling controls and routing before physical keys")

        var pending = try LayerMapping.capture(config: restored, target: target, keys: [2, 3], controlsEnabled: true)
        pending.retainRecovery(from: backup)
        let persisted = try JSONDecoder().decode(LayerMapping.Backup.self, from: JSONEncoder().encode(pending))
        check(persisted.controls?["dial-clockwise"]?.ownedCode == "KV_OAI_AG06")
        check(persisted.controls?["dial-clockwise"]?.recoveryOriginals?["KV_OAI_AG08"] == "KC_VOLU")
        check(try encoded(LayerMapping.restoring(config: applied, backup: persisted)) == encoded(stock))
        let partial = editLayout(applied) { $0["encoders"] = [["KV_OAI_AG06", "KV_OAI_AG09", "KV_OAI_AG10"]] }
        check(try encoded(LayerMapping.restoring(config: partial, backup: persisted)) == encoded(stock))
        pending.finishControlRecovery()
        check(pending.controls?["dial-clockwise"]?.recoveryOriginals == nil)
        check(try encoded(LayerMapping.restoring(config: next, backup: pending)) == encoded(stock))
        print("PASS: persisted reallocation backup restores both failed writes and partially installed control slots")

        let emulator = PadEmulator()
        let device = WLDevice(emulator: emulator)
        try device.connect()
        _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": String(decoding: encoded(applied), as: UTF8.self)])
        var reports: [Int] = []
        device.onNotification = { method, params in
            guard method == OAI.notifyHID, let value = params as? [String: Any], value["act"] as? Int == 1,
                  let slot = OAI.agIndex(value["k"] as? String) else { return }
            reports.append(slot)
        }
        for input in [Pad.dialUpID, Pad.dialPressID, Pad.dialDownID, Pad.joySouthID] { emulator.press(input) }
        try await Task.sleep(nanoseconds: 100_000_000)
        check(reports == [8, 10, 9, 11])
        try emulator.activate(LayerTarget(profileID: 0, layerID: 1))
        check(emulator.slot(forPhysicalKey: Pad.dialPressID) == nil && emulator.slot(forPhysicalKey: Pad.joySouthID) == nil)
        print("PASS: emulator dial press, rotation and joystick focus events use the active layer's allocated slots")

        let queue = OrderedInputQueue<T3MicroAction>()
        let actions: [T3MicroAction] = [.dialClockwise, .dialClockwise, .dialPress, .settleThread,
                                       .dialCounterclockwise, .composerToggle, .newThread, .dialPress]
        var delivered: [T3MicroAction] = []
        for action in actions {
            queue.enqueue(action) { action in
                try? await Task.sleep(nanoseconds: action == .dialClockwise ? 15_000_000 : 1_000_000)
                delivered.append(action)
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        check(delivered == actions)
        var started = false
        var cancelled = false
        queue.enqueue(.dialPress) { _ in
            started = true
            do { try await Task.sleep(nanoseconds: 1_000_000_000); preconditionFailure("Cancelled action ran") }
            catch { cancelled = true }
        }
        queue.enqueue(.composerToggle) { _ in preconditionFailure("Queued action survived cancellation") }
        while !started { await Task.yield() }
        queue.cancel()
        queue.enqueue(.dialCounterclockwise) { delivered.append($0) }
        try await Task.sleep(nanoseconds: 30_000_000)
        check(cancelled && delivered == actions + [.dialCounterclockwise])
        print("PASS: mixed rotations/presses retain order; cancellation drops queued and in-flight work")

        let bridge = BridgeController(providerFactory: { _ in DemoSessionProvider() })
        await bridge.startDemo()
        var controlConfiguration = bridge.configuration
        controlConfiguration.provider = .t3
        controlConfiguration.microControlsEnabled = true
        controlConfiguration.actionButtons = [6: .settleThread, 7: .newThread]
        await bridge.saveConfiguration(controlConfiguration)
        await bridge.applyMapping()
        check(bridge.isRunning && bridge.keymapReady && bridge.layerActive, bridge.lastError ?? "Demo setup failed")
        check(bridge.emulator!.slot(forPhysicalKey: 6) == 12 && bridge.emulator!.slot(forPhysicalKey: 7) == 13)
        check(bridge.assignments[6] == nil && bridge.assignments[7] == nil, "Action buttons were assigned sessions")
        let activeTarget = bridge.configuration.target!
        var releaseBlocked: CheckedContinuation<Void, Never>?
        var staleDeliveries = 0
        let event = BridgeController.QueuedInput(slot: 0, generation: 0, frontmostProcessID: nil)
        bridge.inputQueue.enqueue(event) { _ in
            await withCheckedContinuation { releaseBlocked = $0 }
            if !Task.isCancelled { staleDeliveries += 1 }
        }
        bridge.inputQueue.enqueue(event) { _ in staleDeliveries += 1 }
        while releaseBlocked == nil { await Task.yield() }
        try bridge.emulator!.activate(LayerTarget(profileID: 0, layerID: 1))
        await bridge.forceRepaint()
        check(!bridge.layerActive)
        try bridge.emulator!.activate(activeTarget)
        await bridge.forceRepaint()
        check(bridge.layerActive)
        releaseBlocked!.resume()
        try await Task.sleep(nanoseconds: 30_000_000)
        check(staleDeliveries == 0, "Inputs survived an inactive layer and ran when it became active again")
        print("PASS: leaving and returning to the selected layer cancels blocked and queued control events")

        releaseBlocked = nil
        bridge.inputQueue.enqueue(event) { _ in
            await withCheckedContinuation { releaseBlocked = $0 }
            if !Task.isCancelled { staleDeliveries += 1 }
        }
        bridge.inputQueue.enqueue(event) { _ in staleDeliveries += 1 }
        while releaseBlocked == nil { await Task.yield() }
        let validMapping = try LayerMapping.applying(config: stock, target: activeTarget, keys: bridge.configuration.assignedButtonKeys,
                                                     controlsEnabled: true)
        let invalidMapping = editLayout(validMapping) { layout in
            var encoders = layout["encoders"] as! [[String]]
            encoders[0][2] = "KC_MUTE"
            layout["encoders"] = encoders
        }
        _ = bridge.emulator!.handle("fs.write", params: ["file": "keymap.json", "data": String(decoding: try encoded(invalidMapping), as: UTF8.self)])
        await bridge.forceRepaint()
        check(bridge.layerActive && !bridge.keymapReady)
        _ = bridge.emulator!.handle("fs.write", params: ["file": "keymap.json", "data": String(decoding: try encoded(validMapping), as: UTF8.self)])
        await bridge.forceRepaint()
        check(bridge.layerActive && bridge.keymapReady)
        releaseBlocked!.resume()
        try await Task.sleep(nanoseconds: 30_000_000)
        check(staleDeliveries == 0, "Inputs survived invalidation and restoration of the same layer's mapping")
        await bridge.stop()
        print("PASS: editing and restoring the active mapping cancels blocked and queued control events")

        controlConfiguration.microControlsEnabled = false
        await bridge.saveConfiguration(controlConfiguration)
        await bridge.applyMapping()
        check(bridge.keymapReady && bridge.emulator!.slot(forPhysicalKey: 6) == 12)
        check(bridge.emulator!.slot(forPhysicalKey: Pad.dialPressID) == nil)
        controlConfiguration.actionButtons = [:]
        await bridge.saveConfiguration(controlConfiguration)
        await bridge.applyMapping()
        check(bridge.keymapReady && bridge.emulator!.slot(forPhysicalKey: 6) == nil && bridge.emulator!.slot(forPhysicalKey: 7) == nil)
        print("PASS: bridge independently removes dial and action assignments and restores their saved bindings")

        for action in T3MicroAction.allCases {
            let request = T3DesktopClient.MicroRequest(requestId: "request", action: action)
            let requestJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
            check(Set(requestJSON.keys) == ["version", "requestId", "type", "action"])
            check(requestJSON["type"] as? String == "micro-control" && requestJSON["action"] as? String == action.rawValue)
            let response: [String: Any] = ["version": 1, "requestId": "request", "ok": true, "action": action.rawValue]
            try T3DesktopClient.validateResponse(encoded(response), request: request)
            for (field, value) in [("version", 2), ("requestId", "wrong"), ("action", "unknown")] as [(String, Any)] {
                var invalid = response
                invalid[field] = value
                rejects { try T3DesktopClient.validateResponse(encoded(invalid), request: request) }
            }
            var wrongAction = response
            wrongAction["action"] = action == .dialPress ? "dial-clockwise" : "dial-press"
            rejects { try T3DesktopClient.validateResponse(encoded(wrongAction), request: request) }
            rejects { try T3DesktopClient.validateResponse(encoded(["version": 1, "requestId": "request", "ok": false, "message": "Unavailable"]), request: request) }
        }
        print("PASS: strict micro-control request/response action, version, request ID and rejection checks")

        var unavailable = T3ConnectionSettings()
        unavailable.desktopApplicationPath = "/missing-T3-application.app"
        unavailable.desktopSocketPath = "/missing-T3-socket.sock"
        for action in T3MicroAction.allCases {
            do {
                try await T3DesktopClient.sendMicroControl(action, settings: unavailable, expectedFrontmostProcessID: -1)
                preconditionFailure("Sent a control after the frontmost application changed")
            } catch T3DesktopError.notFrontmost { }
        }
        print("PASS: foreground gate rejects controls before preparing an application or connecting a socket")
    }

    @MainActor static func verifyActionButtons() async throws {
        check(MicroControlMapping.fixedActions == [.dialClockwise, .dialCounterclockwise, .dialPress, .composerToggle])
        check(T3MicroAction.assignableActions == [.newThread, .newProject, .composerToggle, .latestMessage,
                                                 .settleThread, .terminalToggle, .commandPalette])
        var configuration = SessionConfiguration()
        configuration.actionButtons = [6: .settleThread, 7: .newThread]
        try configuration.validate()
        check(try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
        var invalid = configuration
        invalid.actionButtons[0] = .newProject
        rejects { try invalid.validate() }
        invalid = configuration
        invalid.actionButtons[13] = .newProject
        rejects { try invalid.validate() }
        invalid = configuration
        invalid.actionButtons[6] = .dialPress
        rejects { try invalid.validate() }
        invalid = configuration
        invalid.t3.openTarget = .browser
        rejects { try invalid.validate() }
        invalid = configuration
        invalid.actionButtons = [6: .settleThread, 7: .newThread, 8: .latestMessage, 9: .terminalToggle, 12: .commandPalette]
        try invalid.validate()
        invalid.microControlsEnabled = true
        rejects { try invalid.validate() }

        let stock = PadEmulator.stockKeymap()
        let target = LayerTarget(profileID: 0, layerID: 0)
        let assigned = configuration.assignedButtonKeys
        let withoutDialBackup = try LayerMapping.capture(config: stock, target: target, keys: assigned)
        let withoutDial = try LayerMapping.applying(config: stock, target: target, keys: assigned)
        let originalLayout = try LayerMapping.selectedLayer(config: stock, target: target).layout
        let withoutDialLayout = try LayerMapping.selectedLayer(config: withoutDial, target: target).layout
        check(try encoded(["encoders": originalLayout["encoders"]!, "joystick": originalLayout["joystick"]!]) ==
            encoded(["encoders": withoutDialLayout["encoders"]!, "joystick": withoutDialLayout["joystick"]!]))
        check(MicroControlMapping.input(slot: 12, sessionKeys: configuration.sessionKeys, controls: [:],
                                       actionButtons: configuration.actionButtons) == .actionButton(6, .settleThread))
        let removedBase = try LayerMapping.restoring(config: withoutDial, backup: withoutDialBackup)
        check(try encoded(LayerMapping.applying(config: removedBase, target: target, keys: configuration.sessionKeys)) ==
            encoded(LayerMapping.applying(config: stock, target: target, keys: configuration.sessionKeys)))

        configuration.microControlsEnabled = true
        try configuration.validate()
        let slots = try MicroControlMapping.slots(config: stock, target: target, sessionKeys: assigned)
        check(slots == [.dialClockwise: 14, .dialCounterclockwise: 15, .dialPress: 16, .composerToggle: 17])
        let backup = try LayerMapping.capture(config: stock, target: target, keys: assigned, controlsEnabled: true)
        let applied = try LayerMapping.applying(config: stock, target: target, keys: assigned, controlsEnabled: true)
        check(LayerMapping.isApplied(config: applied, target: target, keys: assigned, controlsEnabled: true))
        let before = try LayerMapping.layers(in: stock)[0].keymap
        let after = try LayerMapping.layers(in: applied)[0].keymap
        check(after[2] == ["KV_OAI_AG12", "KV_OAI_AG13", before[2][2], before[2][3]])
        check(after[3] == before[3], "Microphone and Enter were changed without an assignment")
        check(try encoded(LayerMapping.restoring(config: applied, backup: backup)) == encoded(stock))
        check(MicroControlMapping.input(slot: 12, sessionKeys: configuration.sessionKeys, controls: slots,
                                       actionButtons: configuration.actionButtons) == .actionButton(6, .settleThread))
        check(MicroControlMapping.input(slot: 13, sessionKeys: configuration.sessionKeys, controls: slots,
                                       actionButtons: configuration.actionButtons) == .actionButton(7, .newThread))
        check(MicroControlMapping.input(slot: 14, sessionKeys: configuration.sessionKeys, controls: slots,
                                       actionButtons: configuration.actionButtons) == .control(.dialClockwise))
        check(MicroControlMapping.input(slot: 6, sessionKeys: configuration.sessionKeys, controls: slots,
                                       actionButtons: configuration.actionButtons) == .sessionKey(0))
        check(MicroControlMapping.input(slot: 18, sessionKeys: configuration.sessionKeys, controls: slots,
                                       actionButtons: configuration.actionButtons) == nil)
        let emulator = PadEmulator()
        let device = WLDevice(emulator: emulator)
        try device.connect()
        _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": String(decoding: encoded(applied), as: UTF8.self)])
        var reports: [Int] = []
        device.onNotification = { method, params in
            guard method == OAI.notifyHID, let value = params as? [String: Any], value["act"] as? Int == 1,
                  let slot = OAI.agIndex(value["k"] as? String) else { return }
            reports.append(slot)
        }
        for key in [6, Pad.dialPressID, 7, 0, 12] { emulator.press(key) }
        try await Task.sleep(nanoseconds: 100_000_000)
        check(reports == [12, 16, 13, 6], "Action, dial, session or unassigned-button routing changed")
        print("PASS: assignable actions persist, reserve separate slots, work without dial opt-in, and restore unassigned shortcuts")
    }
}
