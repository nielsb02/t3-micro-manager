import XCTest
@testable import WLKit

final class LayerMappingTests: XCTestCase {
    func testOptionalCodexReservationUsesFirstSlots() throws {
        XCTAssertEqual(LayerMapping.agentSlot(forPhysicalKey: 0, slotOffset: 0), 0)
        XCTAssertEqual(LayerMapping.agentSlot(forPhysicalKey: 5, slotOffset: 0), 5)
        XCTAssertEqual(LayerMapping.physicalKey(forAgentSlot: 0, slotOffset: 0), 0)
        XCTAssertEqual(LayerMapping.physicalKey(forAgentSlot: 19, slotOffset: 0), nil)
        XCTAssertEqual(LayerMapping.agentSlot(forPhysicalKey: 0, slotOffset: 6), 6)
        XCTAssertEqual(LayerMapping.physicalKey(forAgentSlot: 5, slotOffset: 6), nil)
    }

    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stock-keymap.json")
        return try KeymapManager.parse(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    }

    private func encoded(_ config: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }

    private func edit(_ config: [String: Any], profile: Int = 0, layer: Int = 0,
                      _ update: (inout [String: Any]) -> Void) -> [String: Any] {
        var result = config
        var profiles = config["profiles"] as! [[String: Any]]
        var layers = profiles[profile]["layers"] as! [[String: Any]]
        update(&layers[layer])
        profiles[profile]["layers"] = layers
        result["profiles"] = profiles
        return result
    }

    private func editKeys(_ config: [String: Any], layer: Int = 0,
                          _ update: (inout [[String]]) -> Void) -> [String: Any] {
        edit(config, layer: layer) { layer in
            var layout = layer["layout"] as! [String: Any]
            var keymap = layout["keymap"] as! [[String]]
            update(&keymap)
            layout["keymap"] = keymap
            layer["layout"] = layout
        }
    }

    func testSessionSlotsDoNotOverlapCodex() throws {
        let slots = (0...12).compactMap { LayerMapping.agentSlot(forPhysicalKey: $0) }
        XCTAssertEqual(slots, Array(6...18))
        XCTAssertTrue(Set(slots).isDisjoint(with: Set(0...5)))
        for key in 0...12 {
            XCTAssertEqual(LayerMapping.physicalKey(forAgentSlot: slots[key]), key)
        }
        XCTAssertEqual(LayerMapping.physicalKey(forAgentSlot: 0), nil)
        XCTAssertEqual(LayerMapping.physicalKey(forAgentSlot: 5), nil)
        XCTAssertEqual(LayerMapping.agentSlot(forPhysicalKey: 13), nil)
    }

    func testTopRowPositionsAgreeWithBindingsLightsAndPresses() async throws {
        // Input 0.18.4's Creator Micro V2 visual layout is ["", "00", "01", ""].
        // Assert physical coordinates independently of the emulator's geometry.
        XCTAssertEqual(Pad.displayRows[0], [0, 1])
        XCTAssertEqual(Pad.position(of: Pad.displayRows[0][0])?.column, 0)
        XCTAssertEqual(Pad.position(of: Pad.displayRows[0][1])?.column, 1)

        let emulator = PadEmulator()
        let device = WLDevice(emulator: emulator)
        try device.connect()
        let target = LayerTarget(profileID: 0, layerID: 1)
        let config = try LayerMapping.applying(config: fixture(), target: target, keys: [0, 1])
        XCTAssertEqual(try LayerMapping.layers(in: config)[1].keymap[0], ["KV_OAI_AG06", "KV_OAI_AG07"])
        _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": String(decoding: encoded(config), as: UTF8.self)])
        try emulator.activate(target)
        _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams([
            OAI.Thread(id: 6, color: 0xFF0000, brightness: 1, effect: .solid),
            OAI.Thread(id: 7, color: 0x00FF00, brightness: 1, effect: .solid)
        ]))
        XCTAssertEqual(emulator.light(forPhysicalKey: Pad.displayRows[0][0])?.color, 0xFF0000)
        XCTAssertEqual(emulator.light(forPhysicalKey: Pad.displayRows[0][1])?.color, 0x00FF00)

        var pressed: [Int] = []
        device.onNotification = { _, params in
            guard let event = params as? [String: Any], event["act"] as? Int == 1,
                  let slot = OAI.agIndex(event["k"] as? String) else { return }
            pressed.append(slot)
        }
        emulator.press(0) // Physical left, as identified by Input's matrix.
        emulator.press(1) // Physical right.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(pressed, [6, 7])
        XCTAssertEqual(pressed.compactMap(LayerMapping.physicalKey(forAgentSlot:)), Pad.displayRows[0])
    }

    func testLegacyBackupMigratesAndRetainsOriginalBindings() throws {
        let original = try fixture()
        let target = LayerTarget(profileID: 0, layerID: 1)
        let legacy = editKeys(original, layer: 1) { keys in
            keys[0][0] = "KV_OAI_AG00"
            keys[0][1] = "KV_OAI_AG01"
        }
        let data = Data(#"{"target":{"profileID":0,"layerID":1},"originals":{"0":"KC_NONE","1":"KC_NONE"}}"#.utf8)
        let backup = try JSONDecoder().decode(LayerMapping.Backup.self, from: data)
        XCTAssertFalse(LayerMapping.isApplied(config: legacy, target: target, keys: [0,1]))
        let restored = try LayerMapping.restoring(config: legacy, backup: backup)
        XCTAssertEqual(try encoded(restored), try encoded(original))
        let migratedBackup = try LayerMapping.capture(config: restored, target: target, keys: [0,1])
        let migrated = try LayerMapping.applying(config: restored, target: target, keys: [0,1])
        XCTAssertEqual(try LayerMapping.layers(in: migrated)[1].keymap[0], ["KV_OAI_AG06", "KV_OAI_AG07"])
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: migrated, backup: migratedBackup)), try encoded(original))
    }

    func testListsActualDeviceNamesAndIdentifiers() throws {
        let layers = try LayerMapping.layers(in: fixture())
        XCTAssertEqual(layers.map(\.title), ["Default / Layer 1", "Default / Layer 2", "Default / Layer 3"])
        XCTAssertEqual(layers.map(\.target), (0...2).map { LayerTarget(profileID: 0, layerID: $0) })
        XCTAssertEqual(layers.map(\.id), ["0:0", "0:1", "0:2"])
    }

    func testSelectedButtonsAreTheOnlyChangedConfiguration() throws {
        let config = try fixture()
        let target = LayerTarget(profileID: 0, layerID: 0)
        let next = try LayerMapping.applying(config: config, target: target, keys: [1, 4, 8])
        let expected = editKeys(config) { keys in
            keys[0][1] = "KV_OAI_AG07"
            keys[1][2] = "KV_OAI_AG10"
            keys[2][2] = "KV_OAI_AG14"
        }
        XCTAssertEqual(try encoded(next), try encoded(expected),
                       "Every other key, microphone position, layer, encoder, joystick, light, and macro must survive")
        XCTAssertTrue(LayerMapping.isApplied(config: next, target: target, keys: [1, 4, 8]))
        XCTAssertFalse(LayerMapping.isApplied(config: next, target: target, keys: [0, 1, 4, 8]))
        XCTAssertEqual(try encoded(next), try encoded(LayerMapping.applying(config: next, target: target, keys: [8, 1, 4])))
    }

    func testSpareLayerLeavesCodexLayerByteEquivalent() throws {
        let config = try KeymapManager.withAgentKeymap(fixture())
        let next = try LayerMapping.applying(config: config, target: LayerTarget(profileID: 0, layerID: 1), keys: [2, 5])
        let beforeLayers = try LayerMapping.layers(in: config)
        let afterLayers = try LayerMapping.layers(in: next)
        XCTAssertEqual(beforeLayers[0], afterLayers[0])
        let expected = editKeys(config, layer: 1) { keys in
            keys[1][0] = "KV_OAI_AG08"
            keys[1][3] = "KV_OAI_AG11"
        }
        XCTAssertEqual(try encoded(next), try encoded(expected))
    }

    func testTargetsIDsWhenArraysAreReorderedAndIDsAreNotOffsets() throws {
        var config = try fixture()
        var profile = (config["profiles"] as! [[String: Any]])[0]
        profile["id"] = 42
        var layers = profile["layers"] as! [[String: Any]]
        layers[0]["id"] = 13
        layers[1]["id"] = 77
        layers[2]["id"] = 5
        profile["layers"] = [layers[2], layers[0], layers[1]]
        var otherProfile = profile
        otherProfile["id"] = 17
        config["profiles"] = [otherProfile, profile]
        config["activeProfileId"] = 17

        let target = LayerTarget(profileID: 42, layerID: 77)
        let next = try LayerMapping.applying(config: config, target: target, keys: [0])
        let expected = edit(config, profile: 1, layer: 2) { layer in
            var layout = layer["layout"] as! [String: Any]
            var keymap = layout["keymap"] as! [[String]]
            keymap[0][0] = "KV_OAI_AG06"
            layout["keymap"] = keymap
            layer["layout"] = layout
        }
        XCTAssertEqual(try encoded(next), try encoded(expected))
        XCTAssertTrue(LayerMapping.isActive(status: ["profile_index": 1, "layer_index": 3], config: next, target: target))
        XCTAssertFalse(LayerMapping.isActive(status: ["profile_index": 0, "layer_index": 3], config: next, target: target))
        XCTAssertFalse(LayerMapping.isActive(status: ["layer_index": 3], config: next, target: target))
        var activeConfig = next
        activeConfig["activeProfileId"] = 42
        XCTAssertTrue(LayerMapping.isActive(status: ["layer_index": 3], config: activeConfig, target: target))
    }

    func testMissingOrInvalidStatusDoesNotClaimLayerOwnership() throws {
        let config = try fixture()
        let target = LayerTarget(profileID: 0, layerID: 1)
        XCTAssertTrue(LayerMapping.isActive(status: ["layer_index": 2], config: config, target: target))
        for status: [String: Any] in [[:], ["layer_index": 0], ["layer_index": -1], ["layer_index": 100],
                                       ["layer_index": 1], ["layer_index": "2"],
                                       ["layer_index": 2, "profile_index": -1],
                                       ["layer_index": 2, "profile_index": 99]] {
            XCTAssertFalse(LayerMapping.isActive(status: status, config: config, target: target), "\(status)")
        }
    }

    func testInvalidTargetsAndKeysAreRejectedWithoutPartialChanges() throws {
        let config = try fixture()
        let target = LayerTarget(profileID: 0, layerID: 0)
        for keys in [[], [1, 1], [-1], [13], [0, 20]] {
            XCTAssertThrowsError(try LayerMapping.applying(config: config, target: target, keys: keys))
            XCTAssertFalse(LayerMapping.isApplied(config: config, target: target, keys: keys))
        }
        XCTAssertThrowsError(try LayerMapping.applying(config: config, target: LayerTarget(profileID: 9, layerID: 0), keys: [0]))
        XCTAssertThrowsError(try LayerMapping.applying(config: config, target: LayerTarget(profileID: 0, layerID: 9), keys: [0]))
        let missingButton = editKeys(config) { $0[1] = [] }
        XCTAssertThrowsError(try LayerMapping.applying(config: missingButton, target: target, keys: [2]))
        XCTAssertThrowsError(try LayerMapping.layers(in: [:]))
        let duplicateLayer = edit(config, layer: 1) { $0["id"] = 0 }
        XCTAssertThrowsError(try LayerMapping.applying(config: duplicateLayer, target: target, keys: [0]))
    }

    func testExistingAgentCodeOnAnotherControlIsRejected() throws {
        let config = try fixture()
        let target = LayerTarget(profileID: 0, layerID: 0)
        let keyConflict = editKeys(config) { $0[2][2] = "KV_OAI_AG06" }
        XCTAssertThrowsError(try LayerMapping.applying(config: keyConflict, target: target, keys: [0]))
        let encoderConflict = edit(config) { layer in
            var layout = layer["layout"] as! [String: Any]
            layout["encoders"] = [["KV_OAI_AG06", "KC_VOLD", "KC_MPLY"]]
            layer["layout"] = layout
        }
        XCTAssertThrowsError(try LayerMapping.applying(config: encoderConflict, target: target, keys: [0]))
    }

    func testBackupRoundTripsAndRestorePreservesLaterInputEdits() throws {
        let config = try fixture()
        let target = LayerTarget(profileID: 0, layerID: 1)
        let backup = try LayerMapping.capture(config: config, target: target, keys: [0, 3, 7])
        let decoded = try JSONDecoder().decode(LayerMapping.Backup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(backup, decoded)
        let applied = try LayerMapping.applying(config: config, target: target, keys: [0, 3, 7])
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: applied, backup: decoded)), try encoded(config))

        var changed = editKeys(applied, layer: 1) { $0[1][1] = "KC_MUTE" }
        changed = editKeys(changed) { $0[0][0] = "KC_ESC" }
        let restored = try LayerMapping.restoring(config: changed, backup: decoded)
        var expected = editKeys(config, layer: 1) { $0[1][1] = "KC_MUTE" }
        expected = editKeys(expected) { $0[0][0] = "KC_ESC" }
        XCTAssertEqual(try encoded(restored), try encoded(expected))
        XCTAssertEqual(try encoded(LayerMapping.restoring(config: restored, backup: decoded)), try encoded(expected))
    }

    func testEmulatorSwitchesBindingAndStatusWithoutRewritingOtherLayers() async throws {
        let emulator = PadEmulator()
        let device = WLDevice(emulator: emulator)
        try device.connect()
        let config = try LayerMapping.applying(config: fixture(), target: LayerTarget(profileID: 0, layerID: 1), keys: [0, 4])
        let payload = String(data: try encoded(config), encoding: .utf8)!
        _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": payload])
        XCTAssertTrue(emulator.bound.isEmpty)
        try emulator.activate(LayerTarget(profileID: 0, layerID: 1))
        XCTAssertEqual(emulator.bound, [6, 10])
        let rawStatus = try await device.callAsync("device.status")
        let status = try XCTUnwrap(rawStatus as? [String: Any])
        XCTAssertTrue(LayerMapping.isActive(status: status, config: config, target: emulator.activeLayer))
        XCTAssertEqual(status["layer_index"] as? Int, 2)
        try emulator.activate(LayerTarget(profileID: 0, layerID: 0))
        XCTAssertTrue(emulator.bound.isEmpty)
        XCTAssertThrowsError(try emulator.activate(LayerTarget(profileID: 0, layerID: 20)))
    }
}
