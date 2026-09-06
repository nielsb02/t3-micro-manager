import Foundation
import Darwin

public enum SessionProviderKind: String, Codable, CaseIterable, Sendable {
    case t3, herdr, demo
    public var title: String { switch self { case .t3: return "T3 Code"; case .herdr: return "Herdr"; case .demo: return "Demo sessions" } }
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

public struct SessionConfiguration: Codable, Equatable, Sendable {
    public var provider: SessionProviderKind = .t3
    public var t3 = T3ConnectionSettings()
    public var target: LayerTarget?
    public var sessionKeys: [Int] = Pad.agentKeyIDs
    public var selection: SessionSelectionMode = .mixed
    private var pinsByProvider: [String: [Int: String]] = [:]
    public var pinnedSessions: [Int: String] {
        get { pinsByProvider[provider.rawValue] ?? [:] }
        set { pinsByProvider[provider.rawValue] = newValue }
    }
    public var driveAmbient = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case provider, t3, target, sessionKeys, selection, pinnedSessions, pinsByProvider, driveAmbient
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(SessionProviderKind.self, forKey: .provider) ?? .t3
        t3 = try values.decodeIfPresent(T3ConnectionSettings.self, forKey: .t3) ?? T3ConnectionSettings()
        target = try values.decodeIfPresent(LayerTarget.self, forKey: .target)
        sessionKeys = try values.decodeIfPresent([Int].self, forKey: .sessionKeys) ?? Pad.agentKeyIDs
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
        try values.encode(provider, forKey: .provider)
        try values.encode(t3, forKey: .t3)
        try values.encodeIfPresent(target, forKey: .target)
        try values.encode(sessionKeys, forKey: .sessionKeys)
        try values.encode(selection, forKey: .selection)
        try values.encode(driveAmbient, forKey: .driveAmbient)
        try values.encode(pinsByProvider, forKey: .pinsByProvider)
        // Keep the active pins readable if the user rolls back to an earlier local build.
        try values.encode(pinnedSessions, forKey: .pinnedSessions)
    }

    public func hasSameConnection(as other: Self) -> Bool {
        guard provider == other.provider else { return false }
        switch provider {
        case .t3: return t3 == other.t3
        case .herdr, .demo: return true
        }
    }

    public static var fileURL: URL {
        URL(fileURLWithPath: KeyBindings.configPath()).deletingLastPathComponent().appendingPathComponent("bridge.json")
    }
    public static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Self() }
        let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL))
        try configuration.validate()
        return configuration
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
        guard SessionSelectionMode.available(for: provider).contains(selection) else {
            throw ConfigurationError.invalid("This provider does not support app ordering.")
        }
        guard !sessionKeys.isEmpty, Set(sessionKeys).count == sessionKeys.count,
              sessionKeys.allSatisfy({ (0...12).contains($0) }) else {
            throw ConfigurationError.invalid("Choose at least one distinct session key between 0 and 12.")
        }
    }
}

public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
