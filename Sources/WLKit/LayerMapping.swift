import Foundation

public struct LayerTarget: Codable, Equatable, Hashable, Sendable {
    public var profileID: Int
    public var layerID: Int

    public init(profileID: Int, layerID: Int) {
        self.profileID = profileID
        self.layerID = layerID
    }
}

public struct DeviceLayer: Identifiable, Equatable, Sendable {
    public var id: String { "\(target.profileID):\(target.layerID)" }
    public var title: String
    public var target: LayerTarget
    public var keymap: [[String]]

    public init(title: String, target: LayerTarget, keymap: [[String]]) {
        self.title = title
        self.target = target
        self.keymap = keymap
    }
}

/// Owns only the selected switch bindings. Input retains the rest of the device configuration.
public enum LayerMapping {
    public static func agentSlot(forPhysicalKey key: Int) -> Int? {
        agentSlot(forPhysicalKey: key, slotOffset: 6)
    }
    public static func agentSlot(forPhysicalKey key: Int, slotOffset: Int) -> Int? {
        guard [0, 6].contains(slotOffset), (0...12).contains(key) else { return nil }
        return key + slotOffset
    }
    public static func physicalKey(forAgentSlot slot: Int) -> Int? {
        physicalKey(forAgentSlot: slot, slotOffset: 6)
    }
    public static func physicalKey(forAgentSlot slot: Int, slotOffset: Int) -> Int? {
        guard [0, 6].contains(slotOffset), (slotOffset...(slotOffset + 12)).contains(slot) else { return nil }
        return slot - slotOffset
    }
    public static func agentCode(forPhysicalKey key: Int) -> String? {
        agentCode(forPhysicalKey: key, slotOffset: 6)
    }
    public static func agentCode(forPhysicalKey key: Int, slotOffset: Int) -> String? {
        agentSlot(forPhysicalKey: key, slotOffset: slotOffset).map { String(format: "KV_OAI_AG%02d", $0) }
    }

    public struct Backup: Codable, Equatable, Sendable {
        public var target: LayerTarget
        public var originals: [Int: String]
        public var ownedCodes: [Int: String]?
        public var controls: [String: MicroControlMapping.SavedBinding]?

        public init(target: LayerTarget, originals: [Int: String], ownedCodes: [Int: String]? = nil,
                    controls: [String: MicroControlMapping.SavedBinding]? = nil) {
            self.target = target
            self.originals = originals
            self.ownedCodes = ownedCodes
            self.controls = controls
        }

        public func ownedCode(for key: Int) -> String? {
            if let ownedCodes { return ownedCodes[key] }
            // The first release backed up physical keys with same-numbered AG slots.
            return KeymapManager.agCodes.indices.contains(key) ? KeymapManager.agCodes[key] : nil
        }

        mutating func retainRecovery(from previous: Backup) {
            for (key, original) in previous.originals where originals[key] == nil {
                originals[key] = original
                ownedCodes?[key] = previous.ownedCode(for: key)
            }
            for (action, saved) in previous.controls ?? [:] {
                if controls?[action] != nil {
                    controls?[action]?.retainRecovery(from: saved)
                } else {
                    if controls == nil { controls = [:] }
                    controls?[action] = saved
                }
            }
        }

        mutating func finishControlRecovery() {
            for action in controls?.keys.map({ $0 }) ?? [] { controls?[action]?.recoveryOriginals = nil }
        }
    }

    public enum Failure: LocalizedError {
        case invalidConfiguration(String)
        case missingTarget
        case invalidKeys
        case invalidControls(String)
        case conflictingBinding(String)

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let detail):
                return "Could not read device layers: \(detail)."
            case .missingTarget:
                return "The selected profile or layer no longer exists. Read the device mapping again."
            case .invalidControls(let message): return message
            case .invalidKeys:
                return "Select at least one distinct button that exists on this layer."
            case .conflictingBinding(let code):
                return "\(code) is already used by another control on this layer. Change that binding in Input first."
            }
        }
    }

    public static func layers(in config: [String: Any]) throws -> [DeviceLayer] {
        guard let profiles = config["profiles"] as? [[String: Any]], !profiles.isEmpty else {
            throw Failure.invalidConfiguration("no profiles")
        }
        var profileIDs = Set<Int>()
        var result: [DeviceLayer] = []
        for profile in profiles {
            guard let profileID = profile["id"] as? Int, profileID >= 0,
                  profileIDs.insert(profileID).inserted,
                  let layers = profile["layers"] as? [[String: Any]] else {
                throw Failure.invalidConfiguration("missing or duplicate profile ID, or missing layers")
            }
            let profileName = profile["name"] as? String ?? "Profile \(profileID)"
            var layerIDs = Set<Int>()
            for (index, layer) in layers.enumerated() {
                guard let layerID = layer["id"] as? Int, layerID >= 0,
                      layerIDs.insert(layerID).inserted,
                      let layout = layer["layout"] as? [String: Any],
                      let keymap = layout["keymap"] as? [[String]] else {
                    throw Failure.invalidConfiguration("missing or duplicate layer ID, or unreadable button map")
                }
                let layerName = layer["name"] as? String ?? "Layer \(index + 1)"
                result.append(DeviceLayer(
                    title: "\(profileName) / \(layerName)",
                    target: LayerTarget(profileID: profileID, layerID: layerID),
                    keymap: keymap
                ))
            }
        }
        return result
    }

    public static func slotAssignments(keys: [Int], controls: [Int] = [], slotOffset: Int = 6) throws -> [Int: Int] {
        let inputs = keys + controls
        guard [0, 6].contains(slotOffset), !keys.isEmpty, keys.allSatisfy({ (0...12).contains($0) }),
              inputs.allSatisfy({ (0...19).contains($0) }), Set(inputs).count == inputs.count else {
            throw Failure.invalidControls("Each button or control can have one binding. Session keys and controls must be distinct.")
        }
        guard inputs.count <= 20 - slotOffset else {
            throw Failure.invalidControls("This layer uses \(inputs.count) agent slots, but only \(20 - slotOffset) are available. Remove a control or session key, or disable Codex desktop buttons if you do not use them.")
        }
        var slots = Dictionary(uniqueKeysWithValues: inputs.filter { $0 < 13 }.map { ($0, $0 + slotOffset) })
        var available = Array((slotOffset..<20).filter { !slots.values.contains($0) })
        for input in controls.filter({ $0 >= 13 }).sorted() { slots[input] = available.removeFirst() }
        return slots
    }

    public static func applying(config: [String: Any], target: LayerTarget,
                                keys: [Int], controls: [Int] = [], slotOffset: Int = 6, controlsEnabled: Bool = false) throws -> [String: Any] {
        let slots = try slotAssignments(keys: keys, controls: controls, slotOffset: slotOffset)
        let selected = try selectedLayer(config: config, target: target)
        guard !controlsEnabled || controls.isEmpty else { throw Failure.invalidControls("Choose one provider's controls per layer.") }
        let micro = controlsEnabled ? try MicroControlMapping.slots(config: config, target: target, sessionKeys: keys, slotOffset: slotOffset) : [:]
        if !controlsEnabled { try validateConflicts(slots: slots, layout: selected.layout) }
        return try modifyingLayout(config: config, target: target) { layout in
            for (input, slot) in slots { try setBinding(input, code: code(slot), in: &layout) }
            for (action, slot) in micro { try MicroControlMapping.set(code(slot), action: action, layout: &layout) }
        }
    }

    public static func isApplied(config: [String: Any], target: LayerTarget, keys: [Int], controls: [Int] = [], slotOffset: Int = 6, controlsEnabled: Bool = false) -> Bool {
        if controlsEnabled {
            guard let expected = try? applying(config: config, target: target, keys: keys, controls: controls, slotOffset: slotOffset, controlsEnabled: true) else { return false }
            return NSDictionary(dictionary: expected).isEqual(to: config)
        }
        guard let slots = try? slotAssignments(keys: keys, controls: controls, slotOffset: slotOffset),
              let selected = try? selectedLayer(config: config, target: target),
              (try? validateConflicts(slots: slots, layout: selected.layout)) != nil else { return false }
        return slots.allSatisfy { (try? binding($0.key, in: selected.layout)) == code($0.value) }
    }

    /// Device layer indices are one-based positions, while persisted selections use IDs.
    /// Firmware without profile_index falls back to the exported activeProfileId.
    public static func isActive(status: [String: Any], config: [String: Any],
                                target: LayerTarget) -> Bool {
        guard let profiles = config["profiles"] as? [[String: Any]],
              let layerIndex = status["layer_index"] as? Int, layerIndex > 0 else { return false }
        let profile: [String: Any]?
        if status["profile_index"] != nil {
            guard let profileIndex = status["profile_index"] as? Int,
                  profiles.indices.contains(profileIndex) else { return false }
            profile = profiles[profileIndex]
        } else if let activeID = config["activeProfileId"] as? Int {
            profile = profiles.first { $0["id"] as? Int == activeID }
        } else {
            return false
        }
        guard profile?["id"] as? Int == target.profileID,
              let layers = profile?["layers"] as? [[String: Any]],
              layers.indices.contains(layerIndex - 1) else { return false }
        return layers[layerIndex - 1]["id"] as? Int == target.layerID
    }

    public static func capture(config: [String: Any], target: LayerTarget,
                               keys: [Int], controls: [Int] = [], slotOffset: Int = 6, controlsEnabled: Bool = false) throws -> Backup {
        let slots = try slotAssignments(keys: keys, controls: controls, slotOffset: slotOffset)
        let selected = try selectedLayer(config: config, target: target)
        guard !controlsEnabled || controls.isEmpty else { throw Failure.invalidControls("Choose one provider's controls per layer.") }
        var micro: [String: MicroControlMapping.SavedBinding]?
        if controlsEnabled {
            micro = [:]
            for (action, slot) in try MicroControlMapping.slots(config: config, target: target, sessionKeys: keys, slotOffset: slotOffset) {
                micro?[action.rawValue] = .init(original: try MicroControlMapping.binding(action, layout: selected.layout), ownedCode: code(slot))
            }
        }
        return try Backup(target: target,
                          originals: Dictionary(uniqueKeysWithValues: slots.keys.map { ($0, try binding($0, in: selected.layout)) }),
                          ownedCodes: slots.mapValues(code), controls: micro)
    }

    public static func restoring(config: [String: Any], backup: Backup) throws -> [String: Any] {
        try restoring(config: config, backups: [backup])
    }

    static func restoring(config: [String: Any], backups: [Backup]) throws -> [String: Any] {
        guard let target = backups.first?.target, backups.allSatisfy({ $0.target == target }) else { throw Failure.missingTarget }
        return try modifyingLayout(config: config, target: target) { layout in
            for input in Set(backups.flatMap { $0.originals.keys }) {
                guard (0...19).contains(input) else { throw Failure.invalidKeys }
                guard let current = try? binding(input, in: layout) else { continue }
                if let backup = backups.first(where: { $0.originals[input] != nil && $0.ownedCode(for: input) == current }) {
                    try setBinding(input, code: backup.originals[input]!, in: &layout)
                }
            }
            for name in Set(backups.flatMap { Array(($0.controls ?? [:]).keys) }) {
                guard let action = T3MicroAction(rawValue: name),
                      let installed = try? MicroControlMapping.binding(action, layout: layout),
                      let original = backups.lazy.compactMap({ $0.controls?[name]?.original(for: installed) }).first else { continue }
                try MicroControlMapping.set(original, action: action, layout: &layout)
            }
        }
    }

    public static func agentSlots(config: [String: Any], target: LayerTarget) -> Set<Int> {
        guard let layout = try? selectedLayer(config: config, target: target).layout else { return [] }
        func slots(_ value: Any) -> Set<Int> {
            if let code = value as? String, code.hasPrefix("KV_OAI_AG"), let id = Int(code.dropFirst(9)), (0...19).contains(id) { return [id] }
            if let array = value as? [Any] { return array.reduce(into: []) { $0.formUnion(slots($1)) } }
            if let dictionary = value as? [String: Any] { return dictionary.values.reduce(into: []) { $0.formUnion(slots($1)) } }
            return []
        }
        return slots(layout)
    }

    static func validate(keys: [Int], keymap: [[String]]) throws {
        guard !keys.isEmpty, Set(keys).count == keys.count else { throw Failure.invalidKeys }
        for key in keys {
            guard KeymapManager.agCodes.indices.contains(key), let position = Pad.position(of: key),
                  keymap.indices.contains(position.row),
                  keymap[position.row].indices.contains(position.column) else { throw Failure.invalidKeys }
        }
    }

    private static func code(_ slot: Int) -> String { String(format: "KV_OAI_AG%02d", slot) }
    private static func validateConflicts(slots: [Int: Int], layout: [String: Any]) throws {
        var remaining = layout
        for input in slots.keys { try setBinding(input, code: "", in: &remaining) }
        let assigned = Set(slots.values.map(code))
        func check(_ value: Any) throws {
            if let code = value as? String, assigned.contains(code) { throw Failure.conflictingBinding(code) }
            if let array = value as? [Any] { for value in array { try check(value) } }
            if let dictionary = value as? [String: Any] { for value in dictionary.values { try check(value) } }
        }
        try check(remaining)
    }

    private static func encoderIndex(_ input: Int) -> Int? {
        [Pad.dialUpID: 0, Pad.dialDownID: 1, Pad.dialPressID: 2][input]
    }
    private static func sectorIndex(_ input: Int, sectors: [[String: Any]]) -> Int? {
        guard let centre = [Pad.joyNorthID: 0.25, Pad.joyWestID: 0.5, Pad.joySouthID: 0.75, Pad.joyEastID: 0.0][input] else { return nil }
        let matches = sectors.indices.filter { index in
            guard let a1 = sectors[index]["a1"] as? Double, let a2 = sectors[index]["a2"] as? Double else { return false }
            return abs(KeymapManager.sectorCentre(a1, a2) - centre) < 0.01
        }
        return matches.count == 1 ? matches.first : nil
    }
    private static func binding(_ input: Int, in layout: [String: Any]) throws -> String {
        if let position = Pad.position(of: input), let keymap = layout["keymap"] as? [[String]],
           keymap.indices.contains(position.row), keymap[position.row].indices.contains(position.column) {
            return keymap[position.row][position.column]
        }
        if let index = encoderIndex(input), let dial = (layout["encoders"] as? [[String]])?.first, dial.indices.contains(index) { return dial[index] }
        if let sectors = (layout["joystick"] as? [String: Any])?["sectors"] as? [[String: Any]],
           let index = sectorIndex(input, sectors: sectors), let code = sectors[index]["k"] as? String { return code }
        throw Failure.invalidControls("\(Pad.inputTitle(input)) is missing from this layer. Configure its layout in Input, then read the device again.")
    }
    private static func setBinding(_ input: Int, code: String, in layout: inout [String: Any]) throws {
        _ = try binding(input, in: layout)
        if let position = Pad.position(of: input) {
            var keymap = layout["keymap"] as! [[String]]
            keymap[position.row][position.column] = code; layout["keymap"] = keymap
        } else if let index = encoderIndex(input) {
            var encoders = layout["encoders"] as! [[String]]
            encoders[0][index] = code; layout["encoders"] = encoders
        } else {
            var joystick = layout["joystick"] as! [String: Any]
            var sectors = joystick["sectors"] as! [[String: Any]]
            sectors[sectorIndex(input, sectors: sectors)!]["k"] = code
            joystick["sectors"] = sectors; layout["joystick"] = joystick
        }
    }

    static func selectedLayer(config: [String: Any], target: LayerTarget) throws
        -> (profileIndex: Int, layerIndex: Int, layout: [String: Any], keymap: [[String]]) {
        _ = try layers(in: config)
        guard let profiles = config["profiles"] as? [[String: Any]],
              let profileIndex = profiles.firstIndex(where: { $0["id"] as? Int == target.profileID }),
              let layers = profiles[profileIndex]["layers"] as? [[String: Any]],
              let layerIndex = layers.firstIndex(where: { $0["id"] as? Int == target.layerID }),
              let layout = layers[layerIndex]["layout"] as? [String: Any],
              let keymap = layout["keymap"] as? [[String]] else { throw Failure.missingTarget }
        return (profileIndex, layerIndex, layout, keymap)
    }

    private static func modifyingLayout(config: [String: Any], target: LayerTarget,
                                         edit: (inout [String: Any]) throws -> Void) throws -> [String: Any] {
        let selected = try selectedLayer(config: config, target: target)
        var next = config
        var profiles = next["profiles"] as! [[String: Any]]
        var layers = profiles[selected.profileIndex]["layers"] as! [[String: Any]]
        var layout = selected.layout
        try edit(&layout)
        layers[selected.layerIndex]["layout"] = layout
        profiles[selected.profileIndex]["layers"] = layers
        next["profiles"] = profiles
        return next
    }
}
