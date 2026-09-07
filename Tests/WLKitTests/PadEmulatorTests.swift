import XCTest
@testable import WLKit

/// Exercises the emulator through `WLDevice`, the way the bridge reaches it.
///
/// These run everywhere, with no pad attached — which is the point of having
/// an emulator at all. They pin the firmware behaviours that are invisible on
/// real hardware: silent acceptance of any payload, and keys that cannot light
/// until they are bound.
final class PadEmulatorTests: XCTestCase {

    private func connected() throws -> (WLDevice, PadEmulator) {
        let emulator = PadEmulator()
        let device = WLDevice(emulator: emulator)
        try device.connect()
        XCTAssertTrue(device.isConnected)
        return (device, emulator)
    }

    private func write(_ config: [String: Any], to device: WLDevice) async throws {
        let data = try JSONSerialization.data(withJSONObject: config)
        _ = try await device.callAsync("fs.write", params: [
            "file": "keymap.json", "data": String(decoding: data, as: UTF8.self),
        ])
    }

    private func replacingBaseLayout(_ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var config = PadEmulator.stockKeymap()
        var profiles = config["profiles"] as! [[String: Any]]
        var layers = profiles[0]["layers"] as! [[String: Any]]
        var layout = layers[0]["layout"] as! [String: Any]
        edit(&layout)
        layers[0]["layout"] = layout
        profiles[0]["layers"] = layers
        config["profiles"] = profiles
        return config
    }

    func testConnectsWithoutHardware() throws {
        let (device, _) = try connected()
        XCTAssertEqual(device.info?.transport, "emulated")
        device.disconnect(reason: nil)
        XCTAssertFalse(device.isConnected)
    }

    func testAnswersTheBaselineCalls() async throws {
        let (device, _) = try connected()
        let version = try await device.callAsync("sys.version") as? [String: Any]
        XCTAssertEqual(version?["version"] as? String, PadEmulator.firmware)

        let status = try await device.callAsync("device.status") as? [String: Any]
        XCTAssertNotNil(status?["battery"])
    }

    func testUnregisteredMethodIsNotFound() async throws {
        let (device, _) = try connected()
        do {
            _ = try await device.callAsync("v.oai.hid")   // a notification, not callable
            XCTFail("expected Method not found")
        } catch {
            XCTAssertTrue("\(error)".contains("Method not found"), "\(error)")
        }
    }

    /// A stock pad ships with F-keys, so nothing can light until the app binds
    /// them. This is the failure that looks like working code on hardware.
    func testStockKeymapBindsNothingUntilApplied() async throws {
        let (device, emulator) = try connected()
        XCTAssertTrue(emulator.bound.isEmpty, "a stock pad has no AG bindings")

        let config = try await KeymapManager.read(device)
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(config))

        let changed = try await KeymapManager.apply(device)
        XCTAssertTrue(changed)
        for key in Pad.boundKeyIDs {
            XCTAssertTrue(emulator.bound.contains(key), "key \(key) should be bound")
        }
        // The dial and the joystick's cardinals bind too.
        XCTAssertTrue(emulator.bound.isSuperset(of: [Pad.dialUpID, Pad.dialDownID,
                                                     Pad.joyNorthID, Pad.joyEastID,
                                                     Pad.joySouthID, Pad.joyWestID]))
    }

    func testBoundKeyLightsAndUnboundKeyStaysDarkWithoutComplaint() async throws {
        let (device, emulator) = try connected()
        _ = try await KeymapManager.apply(device)

        // Key 19 is inside the firmware's id space but not on the pad, so the
        // app never binds it — the perfect stand-in for an unbound key.
        let threads = [OAI.Thread(id: 0, color: 0xFF0000, brightness: 1, effect: .solid),
                       OAI.Thread(id: 19, color: 0x00FF00, brightness: 1, effect: .solid)]
        let result = try await device.callAsync(OAI.methodThreads,
                                                params: OAI.threadsParams(threads))
        // The firmware says ok to both, which is exactly the trap.
        XCTAssertEqual((result as? [String: Any])?["ok"] as? Int, 1)

        XCTAssertEqual(emulator.keys[0]?.color, 0xFF0000)
        XCTAssertTrue(emulator.keys[0]?.isLit == true)
        XCTAssertTrue(emulator.bound.contains(0))
        XCTAssertFalse(emulator.bound.contains(19), "key 19 is not on the pad")
    }

    func testOmittedFieldsLeaveThatAspectAlone() async throws {
        let (device, emulator) = try connected()
        _ = try await KeymapManager.apply(device)

        _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(
            [OAI.Thread(id: 2, color: 0x123456, brightness: 1, effect: .solid, speed: 0.4)]))
        // Change only the brightness; colour and effect must survive.
        _ = try await device.callAsync(OAI.methodThreads,
                                       params: [["id": 2, "b": 0.25]])
        XCTAssertEqual(emulator.keys[2]?.color, 0x123456)
        XCTAssertEqual(emulator.keys[2]?.effect, .solid)
        XCTAssertEqual(emulator.keys[2]?.brightness, 0.25)
    }

    func testZonesAreStored() async throws {
        let (device, emulator) = try connected()
        _ = try await device.callAsync(OAI.methodRGBConfig, params: OAI.rgbConfigParams(
            keys: .dark, ambient: OAI.Zone(effect: .solid, brightness: 1, color: 0x00C853)))
        XCTAssertEqual(emulator.ambientZone.color, 0x00C853)
        XCTAssertEqual(emulator.keysZone.effect, .off)
    }

    /// The whole point of the virtual pad: pressing a key drives the app.
    func testPressingABoundKeyPushesAHIDReport() async throws {
        let (device, emulator) = try connected()
        _ = try await KeymapManager.apply(device)

        let press = expectation(description: "press reported")
        var seen: [Int] = []
        device.onNotification = { method, params in
            guard method == OAI.notifyHID,
                  let dict = params as? [String: Any],
                  let index = OAI.agIndex(dict["k"] as? String),
                  (dict["act"] as? Int) == 1
            else { return }
            seen.append(index)
            press.fulfill()
        }

        emulator.press(4)
        await fulfillment(of: [press], timeout: 2)
        XCTAssertEqual(seen, [4])
    }

    /// An unbound key sends a keystroke on real hardware, not a report.
    func testPressingAnUnboundKeyReportsNothing() throws {
        let (device, emulator) = try connected()
        var reports = 0
        device.onNotification = { method, _ in
            if method == OAI.notifyHID { reports += 1 }
        }
        emulator.press(0)   // still the stock keymap: nothing is bound
        XCTAssertEqual(reports, 0)
    }

    func testPhysicalButtonUsesItsBoundSlotForLightPressAndRelease() async throws {
        let (device, emulator) = try connected()
        let config = replacingBaseLayout { layout in
            var matrix = layout["keymap"] as! [[String]]
            matrix[1][2] = "KV_OAI_AG18" // Physical button 4.
            layout["keymap"] = matrix
        }
        try await write(config, to: device)
        _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams([
            OAI.Thread(id: 4, color: 0xFF0000, brightness: 1, effect: .solid),
            OAI.Thread(id: 18, color: 0x00FF00, brightness: 1, effect: .solid),
        ]))
        XCTAssertEqual(emulator.slot(forPhysicalKey: 4), 18)
        XCTAssertEqual(emulator.light(forPhysicalKey: 4)?.color, 0x00FF00)
        XCTAssertEqual(emulator.bound, [18])
        XCTAssertNil(emulator.slot(forPhysicalKey: Pad.joyWestID))

        let release = expectation(description: "release uses the slot captured on press")
        var seen: [String] = []
        device.onNotification = { method, params in
            guard method == OAI.notifyHID, let report = params as? [String: Any],
                  let code = report["k"] as? String, let action = report["act"] as? Int else { return }
            seen.append("\(code):\(action)")
            if action == 0 { release.fulfill() }
        }
        emulator.press(4)
        try emulator.activate(LayerTarget(profileID: 0, layerID: 1))
        XCTAssertNil(emulator.slot(forPhysicalKey: 4))
        XCTAssertNil(emulator.light(forPhysicalKey: 4))
        await fulfillment(of: [release], timeout: 2)
        XCTAssertEqual(seen, ["AG18:1", "AG18:0"])
    }

    func testBindingASlotElsewhereDoesNotBindTheSameNumberedControl() async throws {
        let (device, emulator) = try connected()
        let config = replacingBaseLayout { layout in
            var matrix = layout["keymap"] as! [[String]]
            matrix[0] = ["KV_OAI_AG04", "KV_OAI_AG13"]
            matrix[1][0] = "KV_OAI_AG15"
            layout["keymap"] = matrix
        }
        try await write(config, to: device)
        XCTAssertEqual(emulator.bound, [4, 13, 15])
        let unexpected = expectation(description: "unbound controls do not report another control's slot")
        unexpected.isInverted = true
        device.onNotification = { method, _ in
            if method == OAI.notifyHID { unexpected.fulfill() }
        }
        for input in [4, Pad.dialUpID, Pad.joyNorthID] {
            XCTAssertNil(emulator.slot(forPhysicalKey: input))
            emulator.press(input)
        }
        await fulfillment(of: [unexpected], timeout: 0.15)
    }

    func testDialAndJoystickResolveTheirActualBindings() async throws {
        let (device, emulator) = try connected()
        let config = replacingBaseLayout { layout in
            layout["encoders"] = [["KV_OAI_AG19", "KV_OAI_AG18", "KC_MPLY"]]
            layout["joystick"] = ["type": "RADIAL", "sectors": [
                ["k": "KV_OAI_AG11", "a1": 0.1875, "a2": 0.3125],
                ["k": "KV_OAI_AG10", "a1": 0.4375, "a2": 0.5625],
                ["k": "KV_OAI_AG09", "a1": 0.6875, "a2": 0.8125],
                ["k": "KV_OAI_AG08", "a1": 0.9375, "a2": 0.0625],
            ]]
        }
        try await write(config, to: device)
        let presses = expectation(description: "all bound dial and joystick controls report")
        presses.expectedFulfillmentCount = 6
        var seen: [Int] = []
        device.onNotification = { method, params in
            guard method == OAI.notifyHID, let report = params as? [String: Any],
                  report["act"] as? Int == 1, let slot = OAI.agIndex(report["k"] as? String) else { return }
            seen.append(slot)
            presses.fulfill()
        }
        for input in [Pad.dialUpID, Pad.dialDownID, Pad.joyNorthID, Pad.joyWestID,
                      Pad.joySouthID, Pad.joyEastID] {
            emulator.press(input)
        }
        await fulfillment(of: [presses], timeout: 2)
        XCTAssertEqual(seen, [19, 18, 11, 10, 9, 8])
    }

    func testResetReturnsAStockPad() async throws {
        let (device, emulator) = try connected()
        _ = try await KeymapManager.apply(device)
        XCTAssertFalse(emulator.bound.isEmpty)

        emulator.reset()
        XCTAssertTrue(emulator.bound.isEmpty)
        XCTAssertTrue(emulator.keys.isEmpty)
    }

    func testConfiguredDialPressAndFocusToggleUseAllocatedSlotsInOrder() async throws {
        let (device, emulator) = try connected()
        let target = LayerTarget(profileID: 0, layerID: 0)
        let config = try LayerMapping.applying(config: PadEmulator.stockKeymap(), target: target,
                                               keys: [0, 1], controlsEnabled: true)
        try await write(config, to: device)
        XCTAssertEqual(emulator.slot(forPhysicalKey: Pad.dialPressID), 10)
        XCTAssertEqual(emulator.slot(forPhysicalKey: Pad.joySouthID), 11)
        var seen: [Int] = []
        let presses = expectation(description: "four control events")
        presses.expectedFulfillmentCount = 4
        device.onNotification = { method, params in
            guard method == OAI.notifyHID, let report = params as? [String: Any],
                  report["act"] as? Int == 1, let slot = OAI.agIndex(report["k"] as? String) else { return }
            seen.append(slot)
            presses.fulfill()
        }
        for input in [Pad.dialUpID, Pad.dialPressID, Pad.dialDownID, Pad.joySouthID] { emulator.press(input) }
        await fulfillment(of: [presses], timeout: 2)
        XCTAssertEqual(seen, [8, 10, 9, 11])
        try emulator.activate(LayerTarget(profileID: 0, layerID: 1))
        XCTAssertNil(emulator.slot(forPhysicalKey: Pad.dialPressID))
        XCTAssertNil(emulator.slot(forPhysicalKey: Pad.joySouthID))
    }
}
