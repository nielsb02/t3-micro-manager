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
    // Codex uses AG00...AG05. Firmware slots are independent of switch positions.
    public static func agentSlot(forPhysicalKey key: Int) -> Int? {
        (0...12).contains(key) ? key + 6 : nil
    }

    public static func physicalKey(forAgentSlot slot: Int) -> Int? {
        (6...18).contains(slot) ? slot - 6 : nil
    }

    public static func agentCode(forPhysicalKey key: Int) -> String? {
        agentSlot(forPhysicalKey: key).map { String(format: "KV_OAI_AG%02d", $0) }
    }

    public struct Backup: Codable, Equatable, Sendable {
        public var target: LayerTarget
        public var originals: [Int: String]
        public var ownedCodes: [Int: String]?

        public init(target: LayerTarget, originals: [Int: String], ownedCodes: [Int: String]? = nil) {
            self.target = target
            self.originals = originals
            self.ownedCodes = ownedCodes
        }

        public func ownedCode(for key: Int) -> String? {
            if let ownedCodes { return ownedCodes[key] }
            // The first release backed up physical keys with same-numbered AG slots.
            return KeymapManager.agCodes.indices.contains(key) ? KeymapManager.agCodes[key] : nil
        }
    }

    public enum Failure: LocalizedError {
        case invalidConfiguration(String)
        case missingTarget
        case invalidKeys
        case conflictingBinding(String)

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let detail):
                return "Could not read device layers: \(detail)."
            case .missingTarget:
                return "The selected profile or layer no longer exists. Read the device mapping again."
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

    public static func applying(config: [String: Any], target: LayerTarget,
                                keys: [Int]) throws -> [String: Any] {
        let selected = try selectedLayer(config: config, target: target)
        try validate(keys: keys, keymap: selected.keymap)
        try validateConflicts(keys: keys, layout: selected.layout)
        return try modifying(config: config, target: target) { keymap in
            for key in keys {
                let position = Pad.position(of: key)!
                keymap[position.row][position.column] = agentCode(forPhysicalKey: key)!
            }
        }
    }

    public static func isApplied(config: [String: Any], target: LayerTarget, keys: [Int]) -> Bool {
        guard let selected = try? selectedLayer(config: config, target: target),
              (try? validate(keys: keys, keymap: selected.keymap)) != nil,
              (try? validateConflicts(keys: keys, layout: selected.layout)) != nil else { return false }
        return keys.allSatisfy { key in
            guard let position = Pad.position(of: key) else { return false }
            return selected.keymap[position.row][position.column] == agentCode(forPhysicalKey: key)
        }
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
                               keys: [Int]) throws -> Backup {
        let selected = try selectedLayer(config: config, target: target)
        try validate(keys: keys, keymap: selected.keymap)
        let originals = Dictionary(uniqueKeysWithValues: keys.map { key in
            let position = Pad.position(of: key)!
            return (key, selected.keymap[position.row][position.column])
        })
        return Backup(target: target, originals: originals,
                      ownedCodes: Dictionary(uniqueKeysWithValues: keys.map { ($0, agentCode(forPhysicalKey: $0)!) }))
    }

    /// A button edited later in Input keeps that newer binding when the integration is removed.
    public static func restoring(config: [String: Any], backup: Backup) throws -> [String: Any] {
        let selected = try selectedLayer(config: config, target: backup.target)
        try validate(keys: Array(backup.originals.keys), keymap: selected.keymap)
        return try modifying(config: config, target: backup.target) { keymap in
            for (key, original) in backup.originals {
                let position = Pad.position(of: key)!
                if keymap[position.row][position.column] == backup.ownedCode(for: key) {
                    keymap[position.row][position.column] = original
                }
            }
        }
    }

    private static func validate(keys: [Int], keymap: [[String]]) throws {
        guard !keys.isEmpty, Set(keys).count == keys.count else { throw Failure.invalidKeys }
        for key in keys {
            guard KeymapManager.agCodes.indices.contains(key), let position = Pad.position(of: key),
                  keymap.indices.contains(position.row),
                  keymap[position.row].indices.contains(position.column) else { throw Failure.invalidKeys }
        }
    }

    private static func validateConflicts(keys: [Int], layout: [String: Any]) throws {
        var remaining = layout
        var keymap = layout["keymap"] as! [[String]]
        for key in keys {
            let position = Pad.position(of: key)!
            keymap[position.row][position.column] = ""
        }
        remaining["keymap"] = keymap
        let assigned = Set(keys.compactMap { agentCode(forPhysicalKey: $0) })
        func check(_ value: Any) throws {
            if let code = value as? String, assigned.contains(code) {
                throw Failure.conflictingBinding(code)
            } else if let array = value as? [Any] {
                for value in array { try check(value) }
            } else if let dictionary = value as? [String: Any] {
                for value in dictionary.values { try check(value) }
            }
        }
        try check(remaining)
    }

    private static func selectedLayer(config: [String: Any], target: LayerTarget) throws
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

    private static func modifying(config: [String: Any], target: LayerTarget,
                                  edit: (inout [[String]]) -> Void) throws -> [String: Any] {
        let selected = try selectedLayer(config: config, target: target)
        var next = config
        var profiles = next["profiles"] as! [[String: Any]]
        var layers = profiles[selected.profileIndex]["layers"] as! [[String: Any]]
        var layout = selected.layout
        var keymap = selected.keymap
        edit(&keymap)
        layout["keymap"] = keymap
        layers[selected.layerIndex]["layout"] = layout
        profiles[selected.profileIndex]["layers"] = layers
        next["profiles"] = profiles
        return next
    }
}
