import Foundation
import SwiftUI

/// A stand-in for the pad, for working without the hardware to hand.
///
/// It answers the same vendor RPC the firmware does and pushes the same
/// `v.oai.hid` reports back, so the bridge above it cannot tell the difference.
/// `WLDevice` routes to one of these instead of IOKit when it is handed one.
///
/// It reproduces the firmware's awkward behaviours on purpose, because those
/// are the ones worth catching before you meet them on real hardware:
///
///   * it answers `{"ok":1}` to any lighting payload, right or wrong;
///   * a key only lights if it is bound to `KV_OAI_AG*` on the **active
///     layer** — an unbound key accepts its colour in silence and stays dark;
///   * an unbound key sends a keystroke rather than a `v.oai.hid` report, so
///     pressing it here does nothing, exactly as it would on the device.
///
/// It starts from the stock F-key keymap, so the app's binding step has real
/// work to do on first connect.
public final class PadEmulator: ObservableObject {

    public static let firmware = "v0.6.0-rc.10 (emulated)"

    public struct Key: Equatable {
        public var color: Int = 0
        public var brightness: Double = 0
        public var effect: OAI.Effect = .off
        public var speed: Double = 0.5

        /// Off is off, whatever colour was last set.
        public var isLit: Bool { brightness > 0 && effect != .off }
    }

    /// Lighting state by firmware AG slot, independent of physical position.
    /// The firmware accepts up to AG19 and so does this.
    @Published public private(set) var keys: [Int: Key] = [:]
    /// Firmware AG slots used by any control on the active layer.
    @Published public private(set) var bound: Set<Int> = []
    @Published public private(set) var keysZone = OAI.Zone.dark
    @Published public private(set) var ambientZone = OAI.Zone.dark
    /// A short tail of RPC traffic, so the window can show what it was told.
    @Published public private(set) var traffic: [String] = []
    @Published public private(set) var activeLayer = LayerTarget(profileID: 0, layerID: 0)

    public var layers: [DeviceLayer] { (try? LayerMapping.layers(in: keymap)) ?? [] }

    /// Set by `WLDevice` to deliver device-pushed notifications.
    var onNotify: ((String, Any?) -> Void)?

    private var keymap: [String: Any] = PadEmulator.stockKeymap()
    private var inputSlots: [Int: Int] = [:]

    public init() { refreshBinding() }

    /// Physical buttons use positions 0–12; dial and joystick controls use
    /// their `Pad` input IDs. Their AG slots come from the active keymap.
    public func slot(forPhysicalKey key: Int) -> Int? { inputSlots[key] }

    public func light(forPhysicalKey key: Int) -> Key? {
        guard let slot = slot(forPhysicalKey: key) else { return nil }
        return keys[slot]
    }

    // MARK: - The RPC surface

    /// Returns the result, or a message for methods this firmware does not
    /// register — the same "Method not found" the real one answers with. The
    /// (result, error) shape mirrors `WLDevice`'s completion, so the caller
    /// hands it straight on.
    func handle(_ method: String, params: Any?) -> (result: Any?, error: String?) {
        switch method {
        case "sys.version":
            note("sys.version")
            return (["version": PadEmulator.firmware], nil)

        case "device.status":
            note("device.status")
            let profiles = keymap["profiles"] as? [[String: Any]] ?? []
            let profileIndex = profiles.firstIndex { $0["id"] as? Int == activeLayer.profileID }
            let layers = profileIndex.flatMap { profiles[$0]["layers"] as? [[String: Any]] } ?? []
            let layerIndex = layers.firstIndex { $0["id"] as? Int == activeLayer.layerID }
            return (["battery": 87, "is_charging": true,
                     "profile_index": profileIndex ?? -1, "layer_index": layerIndex.map { $0 + 1 } ?? 0], nil)

        case "fs.list":
            note("fs.list")
            return (["files": ["keymap.json"]], nil)

        case "fs.read":
            guard let file = (params as? [String: Any])?["file"] as? String else {
                return (nil, "missing `file`")
            }
            guard file == "keymap.json" else { return (nil, "no such file: \(file)") }
            note("fs.read keymap.json")
            guard let data = try? JSONSerialization.data(withJSONObject: keymap),
                  let text = String(data: data, encoding: .utf8)
            else { return (nil, "could not encode keymap") }
            // Double-encoded, exactly as the device returns it.
            return (["data": text], nil)

        case "fs.write":
            guard let payload = params as? [String: Any],
                  let text = payload["data"] as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                  let config = object as? [String: Any]
            else { return (nil, "bad payload") }
            keymap = config
            reconcileActiveLayer()
            refreshBinding()
            note("fs.write keymap.json — \(bound.count) keys now bound")
            return (["ok": 1], nil)

        case OAI.methodThreads:
            applyThreads(params)
            return (["ok": 1], nil)

        case OAI.methodRGBConfig:
            applyZones(params)
            return (["ok": 1], nil)

        case "host.focused_app":
            return (["ok": 1], nil)

        default:
            // Notifications are not callable, and neither is anything else the
            // firmware never registered.
            return (nil, "Method not found")
        }
    }

    private func applyThreads(_ params: Any?) {
        guard let list = params as? [[String: Any]] else {
            note("v.oai.thstatus — malformed, accepted anyway")
            return
        }
        var changed = 0
        for entry in list {
            guard let id = number(entry["id"]).map({ Int($0) }) else { continue }
            var key = keys[id] ?? Key()
            // Omitted fields leave that aspect alone, as on the device.
            if let c = number(entry["c"]) { key.color = Int(c) }
            if let b = number(entry["b"]) { key.brightness = b }
            if let e = number(entry["e"]) { key.effect = OAI.Effect(rawValue: Int(e)) ?? .off }
            if let s = number(entry["s"]) { key.speed = s }
            keys[id] = key
            changed += 1
        }
        let dark = list.compactMap { number($0["id"]).map { Int($0) } }
            .filter { !bound.contains($0) && (keys[$0]?.isLit ?? false) }
        note("v.oai.thstatus — \(changed) key\(changed == 1 ? "" : "s")"
             + (dark.isEmpty ? "" : ", \(dark.count) unbound and so still dark"))
    }

    private func applyZones(_ params: Any?) {
        guard let payload = params as? [String: Any] else { return }
        if let keysSide = payload["keys"] as? [String: Any] { keysZone = zone(from: keysSide) }
        if let ambient = payload["ambient"] as? [String: Any] { ambientZone = zone(from: ambient) }
        note("v.oai.rgbcfg — zones")
    }

    private func zone(from wire: [String: Any]) -> OAI.Zone {
        OAI.Zone(
            effect: OAI.Effect(rawValue: Int(number(wire["e"]) ?? 0)) ?? .off,
            brightness: number(wire["b"]) ?? 0,
            speed: number(wire["s"]) ?? 0.5,
            magic: number(wire["m"]) ?? 1,
            color: Int(number(wire["c"]) ?? 0)
        )
    }

    /// Wire values arrive as Int or Double depending on the caller, so take
    /// either rather than caring which.
    private func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Input

    /// Press a key on the virtual pad.
    ///
    /// Only AG-bound keys report themselves; the rest send a keystroke to the
    /// OS, which is not this object's business — so pressing an unbound key
    /// here does nothing, just as it would on the pad.
    public func press(_ key: Int) {
        guard let slot = slot(forPhysicalKey: key) else {
            note("key \(key) pressed — not AG-bound, so it sent a keystroke instead")
            return
        }
        note("key \(key) pressed — AG\(String(format: "%02d", slot))")
        emit(key: slot, act: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.emit(key: slot, act: 0)
        }
    }

    private func emit(key: Int, act: Int) {
        onNotify?(OAI.notifyHID, ["k": String(format: "AG%02d", key), "act": act])
    }

    /// The joystick's continuous report, for anything that reads it directly.
    public func deflectJoystick(angle: Double, distance: Double) {
        onNotify?(OAI.notifyJoystick, ["a": angle, "d": distance])
    }

    // MARK: - Keymap

    public func activate(_ target: LayerTarget) throws {
        guard try LayerMapping.layers(in: keymap).contains(where: { $0.target == target }) else {
            throw LayerMapping.Failure.missingTarget
        }
        activeLayer = target
        keymap["activeProfileId"] = target.profileID
        refreshBinding()
        note("active profile \(target.profileID), layer \(target.layerID)")
    }

    private func reconcileActiveLayer() {
        let available = layers
        let activeProfileID = keymap["activeProfileId"] as? Int
        if activeProfileID == activeLayer.profileID,
           available.contains(where: { $0.target == activeLayer }) { return }
        if let layer = available.first(where: { $0.target.profileID == activeProfileID }) {
            activeLayer = layer.target
        }
    }

    /// Every key id bound to a `KV_OAI_AG*` code anywhere on the active layer —
    /// the key grid, the encoder, or a joystick sector.
    private func refreshBinding() {
        var found = Set<Int>()
        var inputs: [Int: Int] = [:]
        func slot(_ value: Any?) -> Int? {
            guard let code = value as? String, code.hasPrefix("KV_OAI_AG"),
                  let slot = Int(code.dropFirst(9)), (0...19).contains(slot) else { return nil }
            return slot
        }
        func scan(_ value: Any) {
            if let text = value as? String {
                if let slot = slot(text) { found.insert(slot) }
            } else if let list = value as? [Any] {
                list.forEach(scan)
            } else if let dict = value as? [String: Any] {
                dict.values.forEach(scan)
            }
        }
        if let profiles = keymap["profiles"] as? [[String: Any]] {
            let profile = profiles.first { $0["id"] as? Int == activeLayer.profileID }
            if let layers = profile?["layers"] as? [[String: Any]],
               let layer = layers.first(where: { $0["id"] as? Int == activeLayer.layerID }) {
                scan(layer)
                if let layout = layer["layout"] as? [String: Any] {
                    if let matrix = layout["keymap"] as? [[String]] {
                        for key in 0..<13 {
                            guard let position = Pad.position(of: key),
                                  matrix.indices.contains(position.row),
                                  matrix[position.row].indices.contains(position.column) else { continue }
                            inputs[key] = slot(matrix[position.row][position.column])
                        }
                    }
                    if let encoders = layout["encoders"] as? [[String]], let dial = encoders.first {
                        if dial.indices.contains(0) { inputs[Pad.dialUpID] = slot(dial[0]) }
                        if dial.indices.contains(1) { inputs[Pad.dialDownID] = slot(dial[1]) }
                    }
                    if let joystick = layout["joystick"] as? [String: Any],
                       let sectors = joystick["sectors"] as? [[String: Any]] {
                        let directions: [(Double, Int)] = [
                            (0.25, Pad.joyNorthID), (0.50, Pad.joyWestID),
                            (0.75, Pad.joySouthID), (0.00, Pad.joyEastID),
                        ]
                        for sector in sectors {
                            guard let a1 = number(sector["a1"]), let a2 = number(sector["a2"]),
                                  let direction = directions.first(where: {
                                      abs(KeymapManager.sectorCentre(a1, a2) - $0.0) < 0.01
                                  }) else { continue }
                            inputs[direction.1] = slot(sector["k"])
                        }
                    }
                }
            }
        }
        inputSlots = inputs
        bound = found
    }

    private func note(_ line: String) {
        traffic.append(line)
        if traffic.count > 80 { traffic.removeFirst(traffic.count - 80) }
    }

    /// Reset to a factory pad: stock keymap, every light off.
    public func reset() {
        keymap = PadEmulator.stockKeymap()
        activeLayer = LayerTarget(profileID: 0, layerID: 0)
        keys = [:]
        keysZone = .dark
        ambientZone = .dark
        traffic = []
        refreshBinding()
        note("reset to the stock F-key keymap")
    }

    /// The map a pad ships with: F13–F24 across the keys, volume on the dial,
    /// a numpad ring on the joystick. Matches a real `fs.read` off a stock
    /// device, which is what makes the app's binding step meaningful here.
    static func stockKeymap() -> [String: Any] {
        var config: [String: Any] = [
            "version": 1,
            "activeProfileId": 0,
            "profiles": [[
                "id": 0,
                "name": "Default",
                "layers": [[
                    "id": 0,
                    "name": "Base",
                    "layout": [
                        "keymap": [
                            ["KC_F13", "KC_F14"],
                            ["KC_F15", "KC_F16", "KC_F17", "KC_F18"],
                            ["KC_F19", "KC_F20", "KC_F21", "KC_F22"],
                            ["KC_F23", "KC_NONE", "KC_F24"],
                        ],
                        "encoders": [["KC_VOLU", "KC_VOLD", "KC_MPLY"]],
                        "joystick": [
                            "type": "RADIAL",
                            "sectors": [
                                ["k": "KI_X", "a1": 0.1875, "a2": 0.3125],
                                ["k": "KC_P1", "a1": 0.3125, "a2": 0.4375],
                                ["k": "KC_P2", "a1": 0.4375, "a2": 0.5625],
                                ["k": "KC_P3", "a1": 0.5625, "a2": 0.6875],
                                ["k": "KC_P4", "a1": 0.6875, "a2": 0.8125],
                                ["k": "KC_P5", "a1": 0.8125, "a2": 0.9375],
                                ["k": "KC_P6", "a1": 0.9375, "a2": 0.0625],
                                ["k": "KC_P7", "a1": 0.0625, "a2": 0.1875],
                            ],
                        ],
                    ],
                ]],
            ]],
        ]
        var profiles = config["profiles"] as! [[String: Any]]
        var layers = profiles[0]["layers"] as! [[String: Any]]
        for id in 1...2 {
            layers.append([
                "id": id,
                "name": "Layer \(id + 1)",
                "layout": [
                    "keymap": [2, 4, 4, 3].map { Array(repeating: "KC_NONE", count: $0) },
                    "encoders": [["KC_NONE", "KC_NONE", "KC_NONE"]],
                    "joystick": ["type": "JOYSTICK", "sectors": []],
                ],
            ])
        }
        profiles[0]["layers"] = layers
        config["profiles"] = profiles
        return config
    }
}
