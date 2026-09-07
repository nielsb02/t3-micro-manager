import Foundation
import Darwin
import AppKit

public enum SessionProviderKind: String, Codable, CaseIterable, Sendable {
    case t3, cmux, herdr, demo
    public var title: String { switch self { case .t3: return "T3 Code"; case .cmux: return "cmux"; case .herdr: return "Herdr"; case .demo: return "Demo sessions" } }
}

public enum SessionSelectionMode: String, Codable, CaseIterable, Sendable {
    case pinned, recent, mixed, providerOrder
    public var title: String {
        switch self {
        case .pinned: return "Pinned"
        case .recent: return "Recent"
        case .mixed: return "Pinned + recent"
        case .providerOrder: return "App order"
        }
    }
    public func title(for provider: SessionProviderKind) -> String {
        self == .providerOrder && provider == .t3 ? "T3 sidebar order" : title
    }
    public var usesExplicitPins: Bool { self == .pinned || self == .mixed }
    public static func available(for provider: SessionProviderKind) -> [Self] {
        provider == .t3 ? allCases : [.pinned, .recent, .mixed]
    }
}

public struct T3ConnectionSettings: Codable, Equatable, Sendable {
    public var baseURL = "http://127.0.0.1:3773"
    public var bearerToken = ""
    public var environmentID = ""
    public var openTarget: T3OpenTarget = .desktop
    public var desktopSocketPath = ""
    public var desktopApplicationPath = ""
    public init() {}

    private enum CodingKeys: String, CodingKey { case baseURL, bearerToken, environmentID, openTarget, desktopSocketPath, desktopApplicationPath }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? "http://127.0.0.1:3773"
        bearerToken = try values.decodeIfPresent(String.self, forKey: .bearerToken) ?? ""
        environmentID = try values.decodeIfPresent(String.self, forKey: .environmentID) ?? ""
        // Existing installations retain their working browser target until desktop setup is complete.
        openTarget = try values.decodeIfPresent(T3OpenTarget.self, forKey: .openTarget) ?? .browser
        desktopSocketPath = try values.decodeIfPresent(String.self, forKey: .desktopSocketPath) ?? ""
        desktopApplicationPath = try values.decodeIfPresent(String.self, forKey: .desktopApplicationPath) ?? ""
    }
}

public enum T3OpenTarget: String, Codable, CaseIterable, Sendable {
    case desktop, browser
    public var title: String { self == .desktop ? "T3 desktop app" : "Browser" }
}

public struct SessionLayerConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name = "My layer"
    public var provider: SessionProviderKind = .t3
    public var t3 = T3ConnectionSettings()
    public var cmux = CmuxConnectionSettings()
    public var target: LayerTarget?
    public var sessionKeys: [Int] = Pad.agentKeyIDs
    public var controlBindings: [SessionControlBinding] = []
    public var selection: SessionSelectionMode = .mixed
    private var pinsByProvider: [String: [Int: String]] = [:]
    public var driveAmbient = false
    public init() {}

    private var pinScope: String {
        provider == .cmux && cmux.scope == .workspace ? "cmux:workspace:\(cmux.workspaceID)" : provider.rawValue
    }
    public var pinnedSessions: [Int: String] {
        get { pinsByProvider[pinScope] ?? [:] }
        set { pinsByProvider[pinScope] = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, t3, cmux, target, sessionKeys, controlBindings, selection, pinnedSessions, pinsByProvider, driveAmbient
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        provider = try values.decodeIfPresent(SessionProviderKind.self, forKey: .provider) ?? .t3
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? provider.title
        t3 = try values.decodeIfPresent(T3ConnectionSettings.self, forKey: .t3) ?? T3ConnectionSettings()
        cmux = try values.decodeIfPresent(CmuxConnectionSettings.self, forKey: .cmux) ?? CmuxConnectionSettings()
        target = try values.decodeIfPresent(LayerTarget.self, forKey: .target)
        sessionKeys = try values.decodeIfPresent([Int].self, forKey: .sessionKeys) ?? Pad.agentKeyIDs
        controlBindings = try values.decodeIfPresent([SessionControlBinding].self, forKey: .controlBindings) ?? []
        selection = try values.decodeIfPresent(SessionSelectionMode.self, forKey: .selection) ?? .mixed
        driveAmbient = try values.decodeIfPresent(Bool.self, forKey: .driveAmbient) ?? false
        if let scoped = try values.decodeIfPresent([String: [Int: String]].self, forKey: .pinsByProvider) {
            pinsByProvider = scoped
        } else {
            pinsByProvider = [provider.rawValue: try values.decodeIfPresent([Int: String].self, forKey: .pinnedSessions) ?? [:]]
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(provider, forKey: .provider)
        try values.encode(t3, forKey: .t3)
        try values.encode(cmux, forKey: .cmux)
        try values.encodeIfPresent(target, forKey: .target)
        try values.encode(sessionKeys, forKey: .sessionKeys)
        try values.encode(controlBindings, forKey: .controlBindings)
        try values.encode(selection, forKey: .selection)
        try values.encode(driveAmbient, forKey: .driveAmbient)
        try values.encode(pinsByProvider, forKey: .pinsByProvider)
        try values.encode(pinnedSessions, forKey: .pinnedSessions)
    }
}

public struct SessionConfiguration: Codable, Equatable, Sendable {
    public var layers: [SessionLayerConfiguration]
    public var selectedLayerID: String
    public var reserveCodexSlots: Bool
    public static var codexInstalled: Bool {
        ["/Applications/Codex.app", NSHomeDirectory() + "/Applications/Codex.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") != nil
    }
    public init(reserveCodexSlots: Bool = Self.codexInstalled) {
        let layer = SessionLayerConfiguration()
        layers = [layer]; selectedLayerID = layer.id
        self.reserveCodexSlots = reserveCodexSlots
    }
    private var selectedIndex: Int { layers.firstIndex { $0.id == selectedLayerID } ?? 0 }
    public var selectedLayer: SessionLayerConfiguration {
        get { layers[selectedIndex] }
        set { layers[selectedIndex] = newValue }
    }
    public var slotOffset: Int { reserveCodexSlots ? 6 : 0 }
    public var provider: SessionProviderKind { get { selectedLayer.provider } set { selectedLayer.provider = newValue } }
    public var t3: T3ConnectionSettings { get { selectedLayer.t3 } set { selectedLayer.t3 = newValue } }
    public var cmux: CmuxConnectionSettings { get { selectedLayer.cmux } set { selectedLayer.cmux = newValue } }
    public var target: LayerTarget? { get { selectedLayer.target } set { selectedLayer.target = newValue } }
    public var sessionKeys: [Int] { get { selectedLayer.sessionKeys } set { selectedLayer.sessionKeys = newValue } }
    public var controlBindings: [SessionControlBinding] { get { selectedLayer.controlBindings } set { selectedLayer.controlBindings = newValue } }
    public var activeControlBindings: [SessionControlBinding] { provider == .cmux ? controlBindings : [] }
    public var selection: SessionSelectionMode { get { selectedLayer.selection } set { selectedLayer.selection = newValue } }
    public var pinnedSessions: [Int: String] { get { selectedLayer.pinnedSessions } set { selectedLayer.pinnedSessions = newValue } }
    public var driveAmbient: Bool { get { selectedLayer.driveAmbient } set { selectedLayer.driveAmbient = newValue } }

    @discardableResult public mutating func addLayer(provider: SessionProviderKind = .cmux) -> String {
        var layer = SessionLayerConfiguration()
        layer.provider = provider; layer.name = provider.title
        layers.append(layer); selectedLayerID = layer.id
        return layer.id
    }
    public mutating func removeLayer(id: String) {
        guard layers.count > 1 else { return }
        layers.removeAll { $0.id == id }
        if !layers.contains(where: { $0.id == selectedLayerID }) { selectedLayerID = layers[0].id }
    }

    private enum CodingKeys: String, CodingKey { case layers, selectedLayerID, reserveCodexSlots }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let saved = try values.decodeIfPresent([SessionLayerConfiguration].self, forKey: .layers) {
            layers = saved
            selectedLayerID = try values.decode(String.self, forKey: .selectedLayerID)
        } else {
            let legacy = try SessionLayerConfiguration(from: decoder)
            layers = [legacy]; selectedLayerID = legacy.id
        }
        // Existing bindings always excluded Codex. Preserve that allocation during migration.
        reserveCodexSlots = try values.decodeIfPresent(Bool.self, forKey: .reserveCodexSlots) ?? true
        try validate()
    }
    public func hasSameConnection(as other: Self) -> Bool {
        guard provider == other.provider else { return false }
        switch provider {
        case .t3: return t3 == other.t3
        case .cmux: return cmux == other.cmux
        case .herdr, .demo: return true
        }
    }
    public static var fileURL: URL {
        URL(fileURLWithPath: KeyBindings.configPath()).deletingLastPathComponent().appendingPathComponent("bridge.json")
    }
    public static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL))
    }
    public func save() throws {
        try validate()
        let directory = Self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = directory.appendingPathComponent(".bridge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(self),
                                            attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, Self.fileURL.path) == 0 else {
            throw ConfigurationError.invalid("Could not save the local bridge configuration.")
        }
    }
    public func validate() throws {
        guard !layers.isEmpty, Set(layers.map(\.id)).count == layers.count,
              layers.allSatisfy({ !$0.id.isEmpty }), layers.contains(where: { $0.id == selectedLayerID }) else {
            throw ConfigurationError.invalid("Choose a valid layer configuration.")
        }
        var targets = Set<LayerTarget>()
        for layer in layers {
            guard SessionSelectionMode.available(for: layer.provider).contains(layer.selection) else {
                throw ConfigurationError.invalid("This provider does not support app ordering.")
            }
            guard !layer.sessionKeys.isEmpty, Set(layer.sessionKeys).count == layer.sessionKeys.count,
                  layer.sessionKeys.allSatisfy({ (0...12).contains($0) }) else {
                throw ConfigurationError.invalid("Choose at least one distinct session key between 0 and 12 for each layer.")
            }
            if layer.provider == .cmux {
                _ = try LayerMapping.slotAssignments(keys: layer.sessionKeys, controls: layer.controlBindings.map(\.inputID), slotOffset: slotOffset)
            }
            if let target = layer.target, !targets.insert(target).inserted {
                throw ConfigurationError.invalid("Each Micro layer can have one provider. Choose a different device layer.")
            }
        }
    }
}

public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
