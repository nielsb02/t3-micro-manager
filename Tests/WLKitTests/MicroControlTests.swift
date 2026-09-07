import XCTest
@testable import WLKit

final class MicroControlTests: XCTestCase {
    private let target = LayerTarget(profileID: 0, layerID: 0)

    private func editLayout(_ config: [String: Any], _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var config = config
        var profiles = config["profiles"] as! [[String: Any]]
        var layers = profiles[0]["layers"] as! [[String: Any]]
        var layout = layers[0]["layout"] as! [String: Any]
        edit(&layout)
        layers[0]["layout"] = layout
        profiles[0]["layers"] = layers
        config["profiles"] = profiles
        return config
    }

    private func encoded(_ config: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: config, options: .sortedKeys)
    }

    func testLegacyConfigurationKeepsControlsOptedOut() throws {
        let config = try JSONDecoder().decode(SessionConfiguration.self, from: Data(#"{"sessionKeys":[0,1,4]}"#.utf8))
        XCTAssertFalse(config.microControlsEnabled)
        XCTAssertTrue(config.actionButtons.isEmpty)
        XCTAssertEqual(config.sessionKeys, [0, 1, 4])
        XCTAssertFalse(try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(config)).microControlsEnabled)
        var enabled = config
        enabled.microControlsEnabled = true
        try enabled.validate()
        enabled.sessionKeys = Array(0...10)
        XCTAssertThrowsError(try enabled.validate())
        enabled.sessionKeys = [0]
        enabled.provider = .herdr
        try enabled.validate()
        XCTAssertFalse(enabled.activeMicroControlsEnabled)
        enabled.provider = .t3
        enabled.t3.openTarget = .browser
        XCTAssertThrowsError(try enabled.validate())
    }

    func testAllocationSkipsSessionCodexAndOtherControlSlots() throws {
        let stock = editLayout(PadEmulator.stockKeymap()) { layout in
            var matrix = layout["keymap"] as! [[String]]
            matrix[2][0] = "KV_OAI_AG08"
            matrix[2][1] = "KV_OAI_AG05"
            layout["keymap"] = matrix
        }
        let expected: [T3MicroAction: Int] = [.dialClockwise: 9, .dialCounterclockwise: 10, .dialPress: 11, .composerToggle: 12]
        XCTAssertEqual(try MicroControlMapping.slots(config: stock, target: target, sessionKeys: [0, 1]), expected)
        XCTAssertEqual(try MicroControlMapping.slots(config: stock, target: target, sessionKeys: [1, 0]), expected)
        let applied = try LayerMapping.applying(config: stock, target: target, keys: [0, 1], controlsEnabled: true)
        XCTAssertEqual(try MicroControlMapping.slots(config: applied, target: target, sessionKeys: [0, 1]), expected)
        XCTAssertTrue(LayerMapping.isApplied(config: applied, target: target, keys: [0, 1], controlsEnabled: true))
        XCTAssertEqual(try encoded(applied), try encoded(LayerMapping.applying(config: applied, target: target, keys: [0, 1], controlsEnabled: true)))
    }

    func testFirmwareLimitAndSessionCollisionAreRejected() throws {
        let stock = PadEmulator.stockKeymap()
        let slots = try MicroControlMapping.slots(config: stock, target: target, sessionKeys: Array(0...9))
        XCTAssertEqual(Set(slots.values), Set(16...19))
        XCTAssertThrowsError(try LayerMapping.applying(config: stock, target: target, keys: Array(0...10), controlsEnabled: true))
        let crowded = editLayout(stock) { layout in
            layout["other"] = (7...17).map { String(format: "KV_OAI_AG%02d", $0) }
        }
        XCTAssertThrowsError(try LayerMapping.applying(config: crowded, target: target, keys: [0], controlsEnabled: true))
        let conflicting = editLayout(stock) { layout in
            layout["other"] = ["binding": "KV_OAI_AG06"]
        }
        XCTAssertThrowsError(try LayerMapping.applying(config: conflicting, target: target, keys: [0], controlsEnabled: true))
        let missing = editLayout(stock) { $0["encoders"] = [["KC_VOLU", "KC_VOLD"]] }
        XCTAssertThrowsError(try LayerMapping.applying(config: missing, target: target, keys: [0], controlsEnabled: true))
    }

    func testOnlyFourControlsAndSelectedKeysChangeAndRestore() throws {
        let original = editLayout(PadEmulator.stockKeymap()) { layout in
            var matrix = layout["keymap"] as! [[String]]
            matrix[3] = ["WISPR_FLOW", "WISPR_FLOW", "KC_ENT"]
            layout["keymap"] = matrix
            layout["encoders"] = [["KC_VOLU", "KC_VOLD", "KC_MUTE"], ["KC_A", "KC_B", "KC_C"]]
        }
        let backup = try LayerMapping.capture(config: original, target: target, keys: [0, 1], controlsEnabled: true)
        let decoded = try JSONDecoder().decode(LayerMapping.Backup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(decoded, backup)
        let applied = try LayerMapping.applying(config: original, target: target, keys: [0, 1], controlsEnabled: true)
        let expected = editLayout(original) { layout in
            var matrix = layout["keymap"] as! [[String]]
            matrix[0] = ["KV_OAI_AG06", "KV_OAI_AG07"]
            layout["keymap"] = matrix
            layout["encoders"] = [["KV_OAI_AG08", "KV_OAI_AG09", "KV_OAI_AG10"], ["KC_A", "KC_B", "KC_C"]]
            var joystick = layout["joystick"] as! [String: Any]
            var sectors = joystick["sectors"] as! [[String: Any]]
            sectors[4]["k"] = "KV_OAI_AG11"
            joystick["sectors"] = sectors
            layout["joystick"] = joystick
        }
        XCTAssertEqual(try encoded(applied), try encoded(expected))
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: applied, backup: decoded)), try encoded(original))
        let later = editLayout(applied) { $0["encoders"] = [["KC_PLUS", "KV_OAI_AG09", "KC_MPLY"]] }
        let restored = try LayerMapping.restoring(config: later, backup: decoded)
        let expectedRestored = editLayout(original) { $0["encoders"] = [["KC_PLUS", "KC_VOLD", "KC_MPLY"]] }
        XCTAssertEqual(try encoded(restored), try encoded(expectedRestored))
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: restored, backup: decoded)), try encoded(restored))
    }

    func testReallocationRestoresPreviousBindingsBeforeMovingSlots() throws {
        let original = PadEmulator.stockKeymap()
        let firstBackup = try LayerMapping.capture(config: original, target: target, keys: [0, 1], controlsEnabled: true)
        let first = try LayerMapping.applying(config: original, target: target, keys: [0, 1], controlsEnabled: true)
        let base = try LayerMapping.restoring(config: first, backup: firstBackup)
        let nextBackup = try LayerMapping.capture(config: base, target: target, keys: [2, 3], controlsEnabled: true)
        let next = try LayerMapping.applying(config: base, target: target, keys: [2, 3], controlsEnabled: true)
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: next, backup: nextBackup)), try encoded(original))
        let disabled = try LayerMapping.applying(config: base, target: target, keys: [0, 1])
        XCTAssertEqual(try encoded(disabled), try encoded(LayerMapping.applying(config: original, target: target, keys: [0, 1])))
    }

    func testControlSlotsAreRoutedBeforePhysicalKeyNumbers() {
        let controls: [T3MicroAction: Int] = [.dialClockwise: 8, .dialCounterclockwise: 9, .dialPress: 10, .composerToggle: 19]
        XCTAssertEqual(MicroControlMapping.input(slot: 8, sessionKeys: [0, 1, 2], controls: controls), .control(.dialClockwise))
        XCTAssertEqual(MicroControlMapping.input(slot: 19, sessionKeys: [0, 1], controls: controls), .control(.composerToggle))
        XCTAssertEqual(MicroControlMapping.input(slot: 6, sessionKeys: [0, 1], controls: controls), .sessionKey(0))
        XCTAssertNil(MicroControlMapping.input(slot: 5, sessionKeys: [0, 1], controls: controls))
    }

    func testFailedOrPartialReallocationRestoresTheActuallyInstalledCodes() throws {
        let stock = PadEmulator.stockKeymap()
        let previous = try LayerMapping.capture(config: stock, target: target, keys: [0, 1], controlsEnabled: true)
        let installed = try LayerMapping.applying(config: stock, target: target, keys: [0, 1], controlsEnabled: true)
        let base = try LayerMapping.restoring(config: installed, backup: previous)
        var pending = try LayerMapping.capture(config: base, target: target, keys: [2, 3], controlsEnabled: true)
        pending.retainRecovery(from: previous)
        let persisted = try JSONDecoder().decode(LayerMapping.Backup.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(persisted.controls?["dial-clockwise"]?.ownedCode, "KV_OAI_AG06")
        XCTAssertEqual(persisted.controls?["dial-clockwise"]?.recoveryOriginals?["KV_OAI_AG08"], "KC_VOLU")
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: installed, backup: persisted)), try encoded(stock),
                       "A failed write leaves old slots installed after the proposed backup has already been saved")
        let partial = editLayout(installed) { $0["encoders"] = [["KV_OAI_AG06", "KV_OAI_AG09", "KV_OAI_AG10"]] }
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: partial, backup: persisted)), try encoded(stock))
        let applied = try LayerMapping.applying(config: base, target: target, keys: [2, 3], controlsEnabled: true)
        pending.finishControlRecovery()
        XCTAssertNil(pending.controls?["dial-clockwise"]?.recoveryOriginals)
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: applied, backup: pending)), try encoded(stock))
    }

    @MainActor func testMixedActionsPreserveOrderAcrossAsyncWork() async {
        let queue = OrderedInputQueue<T3MicroAction>()
        let actions: [T3MicroAction] = [.dialClockwise, .dialClockwise, .dialPress, .dialCounterclockwise, .composerToggle, .dialPress]
        var delivered: [T3MicroAction] = []
        let finished = expectation(description: "all events delivered")
        for action in actions {
            queue.enqueue(action) { action in
                try? await Task.sleep(nanoseconds: action == .dialClockwise ? 15_000_000 : 1_000_000)
                delivered.append(action)
                if delivered.count == actions.count { finished.fulfill() }
            }
        }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(delivered, actions)
    }

    @MainActor func testCancelDropsQueuedEventsAndCancelsCurrentWork() async {
        let queue = OrderedInputQueue<Int>()
        let started = expectation(description: "first event started")
        let cancelled = expectation(description: "in-flight work cancelled")
        var delivered: [Int] = []
        for value in [1, 2, 3] {
            queue.enqueue(value) { value in
                started.fulfill()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    delivered.append(value)
                } catch { cancelled.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        queue.cancel()
        let resumed = expectation(description: "new generation starts")
        queue.enqueue(4) { value in delivered.append(value); resumed.fulfill() }
        await fulfillment(of: [cancelled, resumed], timeout: 1)
        XCTAssertEqual(delivered, [4])
    }

    func testMicroSocketRequestAndResponseMustMatchActionAndRequestID() throws {
        for action in T3MicroAction.allCases {
            let request = T3DesktopClient.MicroRequest(requestId: "test-request", action: action)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            XCTAssertEqual(Set(json.keys), ["version", "requestId", "type", "action"])
            XCTAssertEqual(json["type"] as? String, "micro-control")
            XCTAssertEqual(json["action"] as? String, action.rawValue)
            let response: [String: Any] = ["version": 1, "requestId": "test-request", "ok": true, "action": action.rawValue]
            try T3DesktopClient.validateResponse(encoded(response), request: request)
            for (field, invalid): (String, Any) in [("version", 2), ("requestId", "other"), ("action", "unknown")] {
                var malformed = response
                malformed[field] = invalid
                XCTAssertThrowsError(try T3DesktopClient.validateResponse(encoded(malformed), request: request))
            }
            var wrongAction = response
            wrongAction["action"] = action == .dialPress ? "dial-clockwise" : "dial-press"
            XCTAssertThrowsError(try T3DesktopClient.validateResponse(encoded(wrongAction), request: request))
            let rejected: [String: Any] = ["version": 1, "requestId": "test-request", "ok": false,
                                           "code": "control-failed", "message": "No active thread."]
            XCTAssertThrowsError(try T3DesktopClient.validateResponse(encoded(rejected), request: request)) { error in
                guard case T3DesktopError.rejected(let message) = error else { return XCTFail("Expected rejection") }
                XCTAssertEqual(message, "No active thread.")
            }
        }
    }

    @MainActor func testForegroundGateDoesNotPrepareOrLaunchAnApplication() async {
        var settings = T3ConnectionSettings()
        settings.desktopApplicationPath = "/missing-T3-application.app"
        settings.desktopSocketPath = "/missing-T3-socket.sock"
        do {
            try await T3DesktopClient.sendMicroControl(.dialPress, settings: settings, expectedFrontmostProcessID: -1)
            XCTFail("Sent a control after the frontmost application changed")
        } catch T3DesktopError.notFrontmost {
        } catch { XCTFail("Foreground must be checked before preparing the application or socket: \(error)") }
    }

    func testActionCatalogDoesNotChangeTheFourFixedHardwareBindings() {
        XCTAssertEqual(MicroControlMapping.fixedActions, [.dialClockwise, .dialCounterclockwise, .dialPress, .composerToggle])
        XCTAssertEqual(T3MicroAction.assignableActions, [.newThread, .newProject, .composerToggle, .latestMessage,
                                                        .settleThread, .terminalToggle, .commandPalette])
        XCTAssertFalse(T3MicroAction.assignableActions.contains(.dialPress))
    }

    func testActionAssignmentsPersistAndRejectSessionOverlapOrExhaustedSlots() throws {
        var configuration = SessionConfiguration(reserveCodexSlots: true)
        configuration.actionButtons = [6: .settleThread, 7: .newThread]
        try configuration.validate()
        XCTAssertEqual(try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(configuration)), configuration)
        configuration.actionButtons[0] = .newProject
        XCTAssertThrowsError(try configuration.validate())
        configuration.actionButtons[0] = nil
        configuration.actionButtons[13] = .newProject
        XCTAssertThrowsError(try configuration.validate())
        configuration.actionButtons[13] = nil
        configuration.actionButtons[6] = .dialPress
        XCTAssertThrowsError(try configuration.validate())
        configuration.actionButtons[6] = .settleThread
        configuration.t3.openTarget = .browser
        XCTAssertThrowsError(try configuration.validate())
        configuration.t3.openTarget = .desktop
        configuration.actionButtons = [6: .settleThread, 7: .newThread, 8: .latestMessage, 9: .terminalToggle, 12: .commandPalette]
        try configuration.validate()
        configuration.microControlsEnabled = true
        XCTAssertThrowsError(try configuration.validate())
    }

    func testActionButtonsReserveSlotsAndRestoreWithoutChangingUnassignedBindings() throws {
        var configuration = SessionConfiguration(reserveCodexSlots: true)
        configuration.actionButtons = [6: .settleThread, 7: .newThread]
        configuration.microControlsEnabled = true
        let original = PadEmulator.stockKeymap()
        let assigned = configuration.assignedButtonKeys
        let slots = try MicroControlMapping.slots(config: original, target: target, sessionKeys: assigned)
        XCTAssertEqual(slots, [.dialClockwise: 14, .dialCounterclockwise: 15, .dialPress: 16, .composerToggle: 17])
        let backup = try LayerMapping.capture(config: original, target: target, keys: assigned, controlsEnabled: true)
        let applied = try LayerMapping.applying(config: original, target: target, keys: assigned, controlsEnabled: true)
        XCTAssertTrue(LayerMapping.isApplied(config: applied, target: target, keys: assigned, controlsEnabled: true))
        let before = try LayerMapping.layers(in: original)[0].keymap
        let after = try LayerMapping.layers(in: applied)[0].keymap
        XCTAssertEqual(after[2][0], "KV_OAI_AG12")
        XCTAssertEqual(after[2][1], "KV_OAI_AG13")
        XCTAssertEqual(after[2][2...3], before[2][2...3])
        XCTAssertEqual(after[3], before[3], "Microphone and Enter remain unassigned")
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: applied, backup: backup)), try encoded(original))
        XCTAssertEqual(MicroControlMapping.input(slot: 12, sessionKeys: configuration.sessionKeys, controls: slots,
                                                actionButtons: configuration.actionButtons), .actionButton(6, .settleThread))
        XCTAssertEqual(MicroControlMapping.input(slot: 13, sessionKeys: configuration.sessionKeys, controls: slots,
                                                actionButtons: configuration.actionButtons), .actionButton(7, .newThread))
        XCTAssertEqual(MicroControlMapping.input(slot: 14, sessionKeys: configuration.sessionKeys, controls: slots,
                                                actionButtons: configuration.actionButtons), .control(.dialClockwise))
        XCTAssertEqual(MicroControlMapping.input(slot: 6, sessionKeys: configuration.sessionKeys, controls: slots,
                                                actionButtons: configuration.actionButtons), .sessionKey(0))
        XCTAssertNil(MicroControlMapping.input(slot: 18, sessionKeys: configuration.sessionKeys, controls: slots,
                                              actionButtons: configuration.actionButtons))
    }

    func testActionButtonsWorkWithoutOptingIntoTheDialAndCanBeRemovedReversibly() throws {
        var configuration = SessionConfiguration(reserveCodexSlots: true)
        configuration.actionButtons = [6: .settleThread]
        let stock = PadEmulator.stockKeymap()
        let backup = try LayerMapping.capture(config: stock, target: target, keys: configuration.assignedButtonKeys)
        let applied = try LayerMapping.applying(config: stock, target: target, keys: configuration.assignedButtonKeys)
        let appliedLayout = try LayerMapping.selectedLayer(config: applied, target: target).layout
        let stockLayout = try LayerMapping.selectedLayer(config: stock, target: target).layout
        XCTAssertEqual(try encoded(["encoders": appliedLayout["encoders"]!, "joystick": appliedLayout["joystick"]!]),
                       try encoded(["encoders": stockLayout["encoders"]!, "joystick": stockLayout["joystick"]!]))
        XCTAssertEqual(MicroControlMapping.input(slot: 12, sessionKeys: configuration.sessionKeys, controls: [:],
                                                actionButtons: configuration.actionButtons), .actionButton(6, .settleThread))
        let restored = try LayerMapping.restoring(config: applied, backup: backup)
        configuration.actionButtons = [:]
        let removed = try LayerMapping.applying(config: restored, target: target, keys: configuration.assignedButtonKeys)
        XCTAssertEqual(try encoded(removed), try encoded(LayerMapping.applying(config: stock, target: target, keys: configuration.sessionKeys)))
    }
}
