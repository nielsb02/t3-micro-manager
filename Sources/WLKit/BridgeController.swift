import Foundation
import SwiftUI
import IOKit.hid

@MainActor
public final class BridgeController: ObservableObject {
    @Published public private(set) var configuration: SessionConfiguration
    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var assignments: [Int: String] = [:]
    @Published public private(set) var availableLayers: [DeviceLayer] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var deviceConnected = false
    @Published public private(set) var keymapReady = false
    @Published public private(set) var permissionDenied = false
    @Published public private(set) var deviceName = "Creator Micro 2"
    @Published public private(set) var firmware = ""
    @Published public private(set) var battery: String?
    @Published public private(set) var keyColors: [Int: Color] = [:]
    @Published public private(set) var keyEffects: [Int: OAI.Effect] = [:]
    @Published public private(set) var aggregateState: SessionStatus?
    @Published public private(set) var lastError: String?
    @Published public private(set) var contendingClient = false
    @Published public private(set) var layerActive = false
    @Published public private(set) var emulator: PadEmulator?
    @Published public private(set) var backupPath: String?
    @Published public private(set) var isBusy = false

    public var brightness: Double
    private let providerFactory: SessionProviderFactory
    private var provider: any SessionProvider
    private var previewConnection: (settings: SessionConfiguration, provider: any SessionProvider)?
    private var device = WLDevice()
    private var deviceKeymap: [String: Any] = [:]
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var generation = 0
    private var issuedIDs = Set<Int>()
    private var previousPicture: String?
    private var acknowledgements = SessionAcknowledgements()
    private var lastExternalTraffic: Date?

    private struct MappingRecord: Codable {
        var deviceIdentity: String
        var backup: LayerMapping.Backup
        var fullExportPath: String
    }
    private var mappingRecord: MappingRecord?
    private var recordURL: URL {
        SessionConfiguration.fileURL.deletingLastPathComponent()
            .appendingPathComponent(emulator == nil ? "mapping-backup.json" : "emulator-mapping-backup.json")
    }
    private var deviceIdentity: String {
        guard let info = device.info else { return "" }
        return "\(info.serial):\(info.product)"
    }

    public init(brightness: Double = 1,
                providerFactory: @escaping SessionProviderFactory = { SessionProviders.make(configuration: $0) }) {
        self.brightness = brightness
        self.providerFactory = providerFactory
        let loaded: SessionConfiguration
        var loadError: String?
        do { loaded = try SessionConfiguration.load() }
        catch { loaded = SessionConfiguration(); loadError = "Configuration: \(error.localizedDescription)" }
        configuration = loaded
        provider = providerFactory(loaded)
        lastError = loadError
        wire()
    }

    private func wire() {
        device.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.deviceConnected = false; self.layerActive = false; self.keymapReady = false
            self.previousPicture = nil
        }
        device.onTX = { [weak self] _, _, id in self?.issuedIDs.insert(id) }
        device.onResponse = { [weak self] id, _, _ in
            guard let self else { return }
            if self.issuedIDs.remove(id) == nil {
                self.lastExternalTraffic = Date()
                self.contendingClient = true
            }
        }
        device.onNotification = { [weak self] method, params in
            guard let self, method == OAI.notifyHID,
                  let value = params as? [String: Any], (value["act"] as? Int) == 1,
                  let slot = OAI.agIndex(value["k"] as? String),
                  let key = LayerMapping.physicalKey(forAgentSlot: slot) else { return }
            Task {
                let epoch = self.generation
                // A layer may change between polls; never dispatch from cached state.
                guard self.isRunning, !self.isBusy, await self.checkLayer(), self.keymapReady,
                      self.isRunning, !self.isBusy, self.generation == epoch else { return }
                self.handleKeyPress(key)
            }
        }
    }

    public func start() async {
        guard !isRunning, !isBusy, stopTask == nil else { return }
        isRunning = true; generation += 1
        let epoch = generation
        await refresh()
        guard isRunning, generation == epoch else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.isRunning else { return }
                await self.refresh()
            }
        }
    }

    public func stop() async {
        if let stopTask { await stopTask.value; return }
        isRunning = false; generation += 1
        pollTask?.cancel(); pollTask = nil
        let pendingRefresh = refreshTask
        pendingRefresh?.cancel()
        let task = Task {
            await pendingRefresh?.value
            await clearOwnedLights()
            previousPicture = nil
            stopTask = nil
        }
        stopTask = task
        await task.value
    }
    public func toggle() async { if isRunning { await stop() } else { await start() } }

    public func useEmulator(_ on: Bool) async {
        guard on != (emulator != nil), !isBusy else { return }
        isBusy = true
        let resume = isRunning
        await stop()
        device.disconnect(reason: nil)
        let pad = on ? PadEmulator() : nil
        emulator = pad; device = WLDevice(emulator: pad)
        deviceConnected = false; availableLayers = []; deviceKeymap = [:]
        mappingRecord = nil; backupPath = nil; contendingClient = false
        lastExternalTraffic = nil; issuedIDs = []
        wire()
        isBusy = false
        if resume { await start() }
    }

    private func connect() async throws {
        if device.isConnected { return }
        if emulator == nil && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        do { try device.connect() }
        catch { permissionDenied = emulator == nil && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted; throw error }
        deviceConnected = true; permissionDenied = false
        deviceName = device.info?.product ?? "Creator Micro 2"
        if let version = try await device.callAsync("sys.version") as? [String: Any] {
            firmware = version["version"] as? String ?? ""
        }
        try await readMapping()
    }

    private func readMapping() async throws {
        deviceKeymap = try await KeymapManager.read(device)
        availableLayers = try LayerMapping.layers(in: deviceKeymap)
        if let data = try? Data(contentsOf: recordURL),
           let record = try? JSONDecoder().decode(MappingRecord.self, from: data),
           record.deviceIdentity == deviceIdentity {
            mappingRecord = record; backupPath = record.fullExportPath
        } else { mappingRecord = nil; backupPath = nil }
        updateMappingReadiness()
    }

    private func updateMappingReadiness() {
        guard let target = configuration.target else { keymapReady = false; return }
        keymapReady = mappingRecord?.backup.target == target
            && configuration.sessionKeys.allSatisfy {
                mappingRecord?.backup.originals[$0] != nil
                    && mappingRecord?.backup.ownedCode(for: $0) == LayerMapping.agentCode(forPhysicalKey: $0)
            }
            && LayerMapping.isApplied(config: deviceKeymap, target: target, keys: configuration.sessionKeys)
    }

    public func inspectDevice() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try await connect(); try await readMapping(); _ = await checkLayer(); lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    @discardableResult private func checkLayer() async -> Bool {
        guard device.isConnected, let target = configuration.target else { layerActive = false; return false }
        do {
            guard let status = try await device.callAsync("device.status") as? [String: Any] else {
                layerActive = false; return false
            }
            if let value = status["battery"] as? Int { battery = "\(value)%" }
            let active = LayerMapping.isActive(status: status, config: deviceKeymap, target: target)
            if active != layerActive { previousPicture = nil }
            layerActive = active
            return active
        } catch { layerActive = false; previousPicture = nil; return false }
    }

    public func saveConfiguration(_ next: SessionConfiguration) async {
        guard !isBusy else { return }
        do { try next.validate() } catch { lastError = error.localizedDescription; return }
        isBusy = true
        let resume = isRunning
        await stop()
        do {
            try next.save()
            if !configuration.hasSameConnection(as: next) {
                provider = providerFactory(next)
                acknowledgements = SessionAcknowledgements()
            }
            configuration = next
            assignments = [:]; sessions = []; keyColors = [:]; keyEffects = [:]
            aggregateState = nil; lastError = nil; updateMappingReadiness()
        } catch {
            isBusy = false
            if resume { await start() }
            lastError = error.localizedDescription
            return
        }
        isBusy = false
        if resume { await start() }
    }

    public func applyMapping() async {
        guard !isBusy else { return }
        isBusy = true
        let resume = isRunning
        await stop()
        do {
            try configuration.validate()
            guard let target = configuration.target else { throw ConfigurationError.invalid("Choose a layer first.") }
            try await connect(); try await readMapping()
            var base = deviceKeymap
            // Restore our prior selected bindings before moving or resizing the mapping.
            if let record = mappingRecord {
                guard record.backup.target == target else {
                    throw ConfigurationError.invalid("Restore the current mapping before applying to another layer. Your original bindings will be kept.")
                }
                base = try LayerMapping.restoring(config: base, backup: record.backup)
            }
            var backup = try LayerMapping.capture(config: base, target: target, keys: configuration.sessionKeys)
            if let previous = mappingRecord {
                for (key, original) in previous.backup.originals where backup.originals[key] == nil {
                    backup.originals[key] = original
                    backup.ownedCodes?[key] = previous.backup.ownedCode(for: key)
                }
            }
            let next = try LayerMapping.applying(config: base, target: target, keys: configuration.sessionKeys)
            let directory = SessionConfiguration.fileURL.deletingLastPathComponent().appendingPathComponent("backups")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let export = directory.appendingPathComponent("keymap-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: deviceKeymap, options: [.prettyPrinted, .sortedKeys]).write(to: export, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: export.path)
            let record = MappingRecord(deviceIdentity: deviceIdentity, backup: backup, fullExportPath: export.path)
            // Persist recovery information before the flash write.
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            mappingRecord = record; backupPath = export.path
            try await writeMapping(next)
            guard LayerMapping.isApplied(config: deviceKeymap, target: target, keys: configuration.sessionKeys) else {
                throw ConfigurationError.invalid("The device did not retain the selected bindings. The backup is available for restoration.")
            }
            lastError = nil
        } catch { lastError = error.localizedDescription }
        isBusy = false
        if resume && lastError == nil { await start() }
    }

    public func restoreMapping() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        await stop()
        do {
            try await connect(); try await readMapping()
            guard let record = mappingRecord else { throw ConfigurationError.invalid("No mapping backup for this device.") }
            let restored = try LayerMapping.restoring(config: deviceKeymap, backup: record.backup)
            try await writeMapping(restored)
            guard NSDictionary(dictionary: restored).isEqual(to: deviceKeymap) else {
                throw ConfigurationError.invalid("Restore verification failed. Keep the saved backup.")
            }
            try FileManager.default.removeItem(at: recordURL)
            mappingRecord = nil; backupPath = nil; updateMappingReadiness(); lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    private func writeMapping(_ value: [String: Any]) async throws {
        let current = try await KeymapManager.read(device)
        guard NSDictionary(dictionary: current).isEqual(to: deviceKeymap) else {
            deviceKeymap = current; updateMappingReadiness()
            throw ConfigurationError.invalid("The mapping changed in Input during setup. Read the layers again and retry.")
        }
        if !NSDictionary(dictionary: value).isEqual(to: deviceKeymap) {
            let data = try JSONSerialization.data(withJSONObject: value)
            _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": String(decoding: data, as: UTF8.self)])
        }
        deviceKeymap = try await KeymapManager.read(device)
        availableLayers = try LayerMapping.layers(in: deviceKeymap)
        updateMappingReadiness(); previousPicture = nil
    }

    public func testConnection(_ settings: SessionConfiguration) async throws -> [AgentSession] {
        try await previewProvider(for: settings).validatedSessions()
    }

    private func previewProvider(for settings: SessionConfiguration) -> any SessionProvider {
        if let previewConnection, previewConnection.settings.hasSameConnection(as: settings) {
            return previewConnection.provider
        }
        let preview = providerFactory(settings)
        previewConnection = (settings, preview)
        return preview
    }

    public func forceRepaint() async { previousPicture = nil; await refresh() }

    private func refresh() async {
        guard isRunning, !isBusy else { return }
        if let refreshTask { await refreshTask.value; return }
        let task = Task {
            defer { refreshTask = nil }
            await performRefresh()
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        let epoch = generation
        let activeProvider = provider
        var failure: String?
        contendingClient = lastExternalTraffic.map { Date().timeIntervalSince($0) < 30 } ?? false
        do {
            let fetched = try await activeProvider.validatedSessions()
            guard isRunning, generation == epoch else { return }
            sessions = activeProvider.acknowledgementMode == .local
                ? acknowledgements.applying(to: fetched) : fetched
            if configuration.selection == .providerOrder {
                sessions = SessionAssignments.orderedByProvider(sessions)
            }
            assignments = SessionAssignments.assign(sessions, configuration: configuration, previous: assignments)
        } catch {
            guard isRunning, generation == epoch else { return }
            failure = error.localizedDescription
            sessions = sessions.map { var stale = $0; stale.status = .unknown; return stale }
        }
        renderPreview()
        do {
            if activeProvider.requiresEmulator && emulator == nil {
                throw ConfigurationError.invalid("Demo sessions use the emulator. Choose Try demo to start.")
            }
            try await connect()
            guard isRunning, generation == epoch else { return }
            // Verify selected bindings periodically too, so Input edits are respected.
            try await readMapping()
            guard await checkLayer(), keymapReady else { lastError = failure; return }
            guard isRunning, generation == epoch else { return }
            try await paint()
        } catch { failure = [failure, error.localizedDescription].compactMap { $0 }.joined(separator: " · ") }
        lastError = failure
    }

    private func light(_ session: AgentSession?, key: Int) -> OAI.Thread {
        guard let session else { return OAI.Thread(id: key, brightness: 0, effect: .off) }
        let appearance = SessionAppearance(status: session.status)
        return OAI.Thread(id: key, color: appearance.color, brightness: brightness,
                          effect: appearance.effect, speed: appearance.speed)
    }
    private var picture: [OAI.Thread] {
        configuration.sessionKeys.map { key in light(sessions.first(where: { $0.id == assignments[key] }), key: key) }
    }
    private func renderPreview() {
        keyColors = [:]; keyEffects = [:]
        for thread in picture {
            guard let color = thread.color, thread.effect != .off else { continue }
            keyColors[thread.id] = Color(packedRGB: color); keyEffects[thread.id] = thread.effect
        }
        aggregateState = SessionStatus.aggregate(sessions)
    }
    private func paint() async throws {
        let threads = picture.map { physical -> OAI.Thread in
            var wire = physical
            wire.id = LayerMapping.agentSlot(forPhysicalKey: physical.id)!
            return wire
        }
        let fingerprint = threads.map { "\($0.id):\($0.color ?? 0):\($0.effect?.rawValue ?? 0):\($0.speed ?? 0):\($0.brightness ?? 0)" }.joined(separator: "|") + (aggregateState?.rawValue ?? "")
        guard fingerprint != previousPicture else { return }
        _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
        if configuration.driveAmbient {
            let aggregate = aggregateState.map { AgentSession(id: "", title: "", status: $0) }
            let thread = light(aggregate, key: 0)
            _ = try await device.callAsync(OAI.methodRGBConfig, params: ["ambient": OAI.Zone(effect: thread.effect ?? .off, brightness: thread.brightness ?? 0, speed: thread.speed ?? 0.5, magic: 1, color: thread.color ?? 0).wire])
        }
        previousPicture = fingerprint
    }
    private func clearOwnedLights() async {
        guard device.isConnected, await checkLayer(), keymapReady else { return }
        let threads = configuration.sessionKeys.compactMap { LayerMapping.agentSlot(forPhysicalKey: $0) }
            .map { OAI.Thread(id: $0, brightness: 0, effect: .off) }
        _ = try? await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
        if configuration.driveAmbient {
            _ = try? await device.callAsync(OAI.methodRGBConfig, params: ["ambient": OAI.Zone.dark.wire])
        }
    }

    public func handleKeyPress(_ key: Int) {
        guard isRunning, !isBusy, let id = assignments[key], let session = sessions.first(where: { $0.id == id }) else { return }
        Task { await focusSession(session) }
    }
    public func focusSession(_ session: AgentSession) async {
        let epoch = generation
        do {
            guard sessions.contains(where: { $0.id == session.id && $0.environmentID == session.environmentID }) else {
                throw SessionProviderError.unavailableSession
            }
            try await performOpen(session, with: provider, acknowledgesCurrent: true)
        } catch {
            if generation == epoch { lastError = error.localizedDescription }
        }
    }

    public func openSession(_ session: AgentSession, using settings: SessionConfiguration) async throws {
        try await performOpen(session, with: previewProvider(for: settings),
                              acknowledgesCurrent: configuration.hasSameConnection(as: settings))
    }

    private func performOpen(_ session: AgentSession, with destination: any SessionProvider,
                             acknowledgesCurrent: Bool) async throws {
        guard !isBusy else { throw SessionProviderError.unavailableSession }
        let epoch = generation
        try await destination.openSession(session)
        guard acknowledgesCurrent, generation == epoch else { return }
        if destination.acknowledgementMode == .local { acknowledgements.acknowledge(session) }
        lastError = nil
        await forceRepaint()
    }

    public var inputCapabilities: SessionInputCapabilities {
        (provider as? any SessionInputProvider)?.inputCapabilities ?? SessionInputCapabilities()
    }

    public func sendInput(_ input: SessionInput, to sessionID: String) async throws {
        guard isRunning, !isBusy, let session = sessions.first(where: { $0.id == sessionID }) else {
            throw SessionProviderError.unavailableSession
        }
        guard let destination = provider as? any SessionInputProvider,
              destination.inputCapabilities.supports(input) else { throw SessionProviderError.unsupportedInput }
        try await destination.sendInput(input, to: session)
    }

    public func noteError(_ message: String) { lastError = message }
    public func startDemo() async {
        guard !isBusy else { return }
        await useEmulator(true)
        guard emulator != nil else { return }
        await inspectDevice()
        guard lastError == nil else { return }
        var next = configuration
        next.provider = .demo; next.target = availableLayers.first?.target
        next.selection = .recent; next.pinnedSessions = [:]
        next.sessionKeys = Pad.agentKeyIDs
        // Demo is intentionally temporary; retain the user's saved real setup.
        await stop()
        provider = providerFactory(next)
        acknowledgements = SessionAcknowledgements()
        configuration = next
        await applyMapping()
        if lastError == nil { await start() }
    }
}
