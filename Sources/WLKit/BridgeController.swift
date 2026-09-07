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
    public var backupPath: String? { mappingRecord?.fullExportPath }
    @Published public private(set) var isBusy = false

    public var brightness: Double
    private let providerFactory: SessionProviderFactory
    private var provider: any SessionProvider
    private var previewConnection: (settings: SessionConfiguration, provider: any SessionProvider)?
    private var device = WLDevice()
    private var deviceKeymap: [String: Any] = [:]
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshedGeneration: Int?
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
        // Non-nil while an attempted write still needs verification. Earlier
        // ownership remains recoverable if the device kept some or all of it.
        var previousBackups: [LayerMapping.Backup]?

        var recoveryBackups: [LayerMapping.Backup] { [backup] + (previousBackups ?? []) }
    }
    private struct MappingArchive: Codable { var records: [MappingRecord] }
    private var mappingRecords: [MappingRecord] = []
    private var mappingRecord: MappingRecord? {
        get { configuration.target.flatMap { mappingRecord(for: $0) } }
        set {
            mappingRecords.removeAll { $0.backup.target == configuration.target }
            if let newValue { mappingRecords.append(newValue) }
        }
    }
    private struct LayerRuntime {
        var settings: SessionConfiguration
        var provider: any SessionProvider
        var sessions: [AgentSession]
        var assignments: [Int: String]
        var acknowledgements: SessionAcknowledgements
    }
    private var layerRuntimes: [String: LayerRuntime] = [:]
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

    @Published public private(set) var dialControlsWorkspaces = false
    public var onShowCommands: (() -> Void)?
    public var onControlOverride: ((SessionControlAction) -> Bool)?
    private var inputTask: Task<Void, Never>?
    private var inputTasks: [UUID: Task<Void, Never>] = [:]

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
                  let slot = OAI.agIndex(value["k"] as? String) else { return }
            guard self.inputTasks.count < 64 else { return }
            let inputID = UUID()
            let previous = self.inputTask
            let queuedGeneration = self.generation
            self.inputTask = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                defer { self.inputTasks[inputID] = nil }
                guard !Task.isCancelled, self.generation == queuedGeneration,
                      self.isRunning, !self.isBusy else { return }
                await self.followActiveLayer()
                let epoch = self.generation
                if self.sessions.isEmpty { await self.refresh() }
                guard self.isRunning, !self.isBusy, await self.checkLayer(), self.keymapReady,
                      self.generation == epoch, !Task.isCancelled else { return }
                let slots = try? LayerMapping.slotAssignments(keys: self.configuration.sessionKeys,
                    controls: self.configuration.activeControlBindings.map(\.inputID), slotOffset: self.configuration.slotOffset)
                if let binding = self.configuration.activeControlBindings.first(where: { slots?[$0.inputID] == slot }) {
                    do { try await self.performControl(binding.action, text: binding.text) }
                    catch { if self.generation == epoch { self.lastError = error.localizedDescription } }
                } else if let key = LayerMapping.physicalKey(forAgentSlot: slot, slotOffset: self.configuration.slotOffset),
                          let id = self.assignments[key], let session = self.sessions.first(where: { $0.id == id }) {
                    await self.focusSession(session)
                }
            }
            self.inputTasks[inputID] = self.inputTask
        }
    }

    public func start() async {
        guard !isRunning, !isBusy, stopTask == nil else { return }
        isRunning = true; generation += 1
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.isRunning else { return }
                await self.refresh()
            }
        }
        await refresh()
    }

    public func stop() async {
        if let stopTask { await stopTask.value; return }
        isRunning = false; generation += 1
        let pendingInputs = Array(inputTasks.values)
        for task in pendingInputs { task.cancel() }
        inputTask = nil
        pollTask?.cancel(); pollTask = nil
        let pendingRefresh = refreshTask
        pendingRefresh?.cancel()
        let task = Task {
            await pendingRefresh?.value
            for task in pendingInputs { await task.value }
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
        mappingRecords = []; contendingClient = false
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
        if let data = try? Data(contentsOf: recordURL) {
            let decoder = JSONDecoder()
            if let archive = try? decoder.decode(MappingArchive.self, from: data) {
                mappingRecords = archive.records.filter { $0.deviceIdentity == deviceIdentity }
            } else if let record = try? decoder.decode(MappingRecord.self, from: data), record.deviceIdentity == deviceIdentity {
                mappingRecords = [record]
            } else {
                throw ConfigurationError.invalid("Could not read the mapping recovery file. Keep its backup before applying bindings.")
            }
        } else { mappingRecords = [] }
        updateMappingReadiness()
    }

    private func updateMappingReadiness() {
        guard let target = configuration.target else { keymapReady = false; return }
        let slots = try? LayerMapping.slotAssignments(keys: configuration.sessionKeys,
            controls: configuration.activeControlBindings.map(\.inputID), slotOffset: configuration.slotOffset)
        keymapReady = mappingRecord?.backup.target == target
            && mappingRecord?.previousBackups == nil && slots != nil
            && slots!.allSatisfy { input, slot in
                mappingRecord?.backup.originals[input] != nil
                    && mappingRecord?.backup.ownedCode(for: input) == String(format: "KV_OAI_AG%02d", slot)
            }
            && LayerMapping.isApplied(config: deviceKeymap, target: target, keys: configuration.sessionKeys,
                controls: configuration.activeControlBindings.map(\.inputID), slotOffset: configuration.slotOffset)
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

    private func cacheCurrentLayer() {
        layerRuntimes[configuration.selectedLayerID] = LayerRuntime(
            settings: configuration, provider: provider, sessions: sessions,
            assignments: assignments, acknowledgements: acknowledgements)
    }

    private func activateLayer(_ id: String) {
        guard id != configuration.selectedLayerID else { return }
        cacheCurrentLayer()
        configuration.selectedLayerID = id
        dialControlsWorkspaces = false
        generation += 1
        if let cached = layerRuntimes[id], cached.settings.hasSameConnection(as: configuration) {
            provider = cached.provider; sessions = cached.sessions
            assignments = cached.assignments; acknowledgements = cached.acknowledgements
        } else {
            provider = providerFactory(configuration)
            sessions = []; assignments = [:]; acknowledgements = SessionAcknowledgements()
        }
        lastError = nil; previousPicture = nil
        updateMappingReadiness(); renderPreview()
    }

    private func followActiveLayer() async {
        guard device.isConnected, isRunning, !isBusy else { return }
        let epoch = generation
        guard let status = try? await device.callAsync("device.status") as? [String: Any],
              isRunning, !isBusy, generation == epoch else { return }
        if let layer = configuration.layers.first(where: { layer in
            layer.target.map { LayerMapping.isActive(status: status, config: deviceKeymap, target: $0) } ?? false
        }) { activateLayer(layer.id) }
    }

    private func mappingRecord(for target: LayerTarget) -> MappingRecord? {
        mappingRecords.first { $0.backup.target == target }
    }
    public func hasAppliedMapping(for target: LayerTarget) -> Bool { mappingRecord(for: target) != nil }
    public func backupPath(for target: LayerTarget) -> String? { mappingRecord(for: target)?.fullExportPath }
    public var slotConflicts: [String] {
        let managedTargets = Set(configuration.layers.compactMap(\.target))
        let managedSlots = Set(configuration.layers.flatMap { layer in
            (try? LayerMapping.slotAssignments(keys: layer.sessionKeys,
                controls: layer.provider == .cmux ? layer.controlBindings.map(\.inputID) : [], slotOffset: configuration.slotOffset)).map { Array($0.values) } ?? []
        })
        return availableLayers.filter { !managedTargets.contains($0.target) }.compactMap { layer in
            let slots = LayerMapping.agentSlots(config: deviceKeymap, target: layer.target).intersection(managedSlots)
            guard !slots.isEmpty else { return nil }
            let names = slots.sorted().map { String(format: "AG%02d", $0) }.joined(separator: ", ")
            return "\(layer.title) also uses \(names). Its controller must respect the active layer."
        }
    }

    public func saveConfiguration(_ next: SessionConfiguration) async {
        guard !isBusy else { return }
        do {
            try next.validate()
            for record in mappingRecords where configuration.layers.contains(where: { $0.target == record.backup.target }) {
                guard next.layers.contains(where: { $0.target == record.backup.target }) else {
                    throw ConfigurationError.invalid("Restore the applied layer's buttons before removing it or choosing another device layer.")
                }
            }
        } catch { lastError = error.localizedDescription; return }
        isBusy = true
        let resume = isRunning
        await stop()
        do {
            try next.save()
            cacheCurrentLayer()
            if configuration.selectedLayerID != next.selectedLayerID {
                if let cached = layerRuntimes[next.selectedLayerID], cached.settings.hasSameConnection(as: next) {
                    provider = cached.provider; acknowledgements = cached.acknowledgements
                } else {
                    provider = providerFactory(next); acknowledgements = SessionAcknowledgements()
                }
            } else if !configuration.hasSameConnection(as: next) {
                provider = providerFactory(next); acknowledgements = SessionAcknowledgements()
            }
            layerRuntimes = layerRuntimes.reduce(into: [:]) { runtimes, entry in
                let (id, previous) = entry
                guard next.layers.contains(where: { $0.id == id }) else { return }
                var settings = next; settings.selectedLayerID = id
                guard previous.settings.hasSameConnection(as: settings) else { return }
                var cached = previous
                if previous.settings.selection != settings.selection
                    || previous.settings.pinnedSessions != settings.pinnedSessions
                    || previous.settings.sessionKeys != settings.sessionKeys {
                    cached.sessions = []; cached.assignments = [:]
                }
                cached.settings = settings
                runtimes[id] = cached
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

    public func applyMapping(for layerID: String? = nil) async {
        guard !isBusy else { return }
        let id = layerID ?? configuration.selectedLayerID
        guard configuration.layers.contains(where: { $0.id == id }) else {
            lastError = "This layer configuration is no longer available."; return
        }
        isBusy = true
        let resume = isRunning
        await stop()
        activateLayer(id)
        do {
            try configuration.validate()
            guard let target = configuration.target else { throw ConfigurationError.invalid("Choose a layer first.") }
            try await connect(); try await readMapping()
            var base = deviceKeymap
            // Restore our prior selected bindings before moving or resizing the mapping.
            if let record = mappingRecord {
                base = try LayerMapping.restoring(config: base, backups: record.recoveryBackups)
            }
            let backup = try LayerMapping.capture(config: base, target: target, keys: configuration.sessionKeys, controls: configuration.activeControlBindings.map(\.inputID), slotOffset: configuration.slotOffset)
            let next = try LayerMapping.applying(config: base, target: target, keys: configuration.sessionKeys, controls: configuration.activeControlBindings.map(\.inputID), slotOffset: configuration.slotOffset)
            let directory = SessionConfiguration.fileURL.deletingLastPathComponent().appendingPathComponent("backups")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let export = directory.appendingPathComponent("keymap-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: deviceKeymap, options: [.prettyPrinted, .sortedKeys]).write(to: export, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: export.path)
            let previousBackups = (mappingRecord?.recoveryBackups ?? []).reduce(into: [LayerMapping.Backup]()) { result, previous in
                if !result.contains(previous) { result.append(previous) }
            }
            var record = MappingRecord(deviceIdentity: deviceIdentity, backup: backup, fullExportPath: export.path,
                                       previousBackups: previousBackups)
            // Persist recovery information before the flash write.
            mappingRecord = record
            try persistMappingRecords()
            try await writeMapping(next)
            guard NSDictionary(dictionary: next).isEqual(to: deviceKeymap),
                  LayerMapping.isApplied(config: deviceKeymap, target: target, keys: configuration.sessionKeys, controls: configuration.activeControlBindings.map(\.inputID), slotOffset: configuration.slotOffset) else {
                throw ConfigurationError.invalid("The device did not retain the selected bindings. The backup is available for restoration.")
            }
            record.previousBackups = nil
            mappingRecord = record
            try persistMappingRecords()
            updateMappingReadiness()
            lastError = nil
        } catch { lastError = error.localizedDescription }
        isBusy = false
        if resume && lastError == nil { await start() }
    }

    private func persistMappingRecords() throws {
        if mappingRecords.isEmpty {
            if FileManager.default.fileExists(atPath: recordURL.path) { try FileManager.default.removeItem(at: recordURL) }
        } else {
            try JSONEncoder().encode(MappingArchive(records: mappingRecords)).write(to: recordURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        }
    }

    public func restoreMapping() async {
        guard let target = configuration.target else { return }
        await restoreMapping(for: target)
    }
    public func restoreMapping(for target: LayerTarget) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        await stop()
        do {
            try await connect(); try await readMapping()
            guard let record = mappingRecord(for: target) else {
                throw ConfigurationError.invalid("No mapping backup for this layer.")
            }
            let restored = try LayerMapping.restoring(config: deviceKeymap, backups: record.recoveryBackups)
            try await writeMapping(restored)
            guard NSDictionary(dictionary: restored).isEqual(to: deviceKeymap) else {
                throw ConfigurationError.invalid("Restore verification failed. Keep the saved backup.")
            }
            mappingRecords.removeAll { $0.backup.target == target }
            try persistMappingRecords()
            updateMappingReadiness(); lastError = nil
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
        while let refreshTask {
            await refreshTask.value
            guard isRunning, !isBusy, !Task.isCancelled else { return }
            if refreshedGeneration == generation { return }
        }
        let task = Task {
            defer { refreshTask = nil }
            await performRefresh()
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        do {
            try await connect()
            try await readMapping()
            await followActiveLayer()
        } catch { }
        guard isRunning, !isBusy, !Task.isCancelled else { return }
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
        refreshedGeneration = epoch
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
            wire.id = LayerMapping.agentSlot(forPhysicalKey: physical.id, slotOffset: configuration.slotOffset)!
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
        let threads = configuration.sessionKeys.compactMap { LayerMapping.agentSlot(forPhysicalKey: $0, slotOffset: configuration.slotOffset) }
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

    public func performControl(_ action: SessionControlAction, text: String = "") async throws {
        guard isRunning, !isBusy, configuration.provider == .cmux else { throw SessionProviderError.unavailableSession }
        if onControlOverride?(action) == true { return }
        if action == .toggleDialMode { dialControlsWorkspaces.toggle(); return }
        if action == .commands { onShowCommands?(); return }
        guard let destination = provider as? any SessionControlProvider else { throw SessionProviderError.unsupportedInput }
        let resolved: SessionControlAction = dialControlsWorkspaces && action == .nextTab ? .nextWorkspace
            : dialControlsWorkspaces && action == .previousTab ? .previousWorkspace : action
        try await destination.performControl(resolved, text: text)
        lastError = nil
    }

    public func executeCmuxCommand(_ text: String, layerID: String) async throws {
        guard isRunning, !isBusy, configuration.selectedLayerID == layerID,
              let destination = provider as? any SessionControlProvider else { throw SessionProviderError.unavailableSession }
        try await destination.executeCommand(text)
        lastError = nil
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

    public func cmuxWorkspaces(using settings: SessionConfiguration) async throws -> [AgentSession] {
        try await CmuxClient(settings: settings.cmux).workspaces()
    }

    public func setCmuxScope(_ scope: CmuxSessionScope, workspaceID: String) async {
        guard configuration.provider == .cmux else { return }
        var next = configuration
        next.cmux.scope = scope; next.cmux.workspaceID = workspaceID
        await saveConfiguration(next)
    }

    public func noteError(_ message: String) { lastError = message }
    public func startDemo() async {
        guard !isBusy else { return }
        await useEmulator(true)
        guard emulator != nil else { return }
        await inspectDevice()
        guard lastError == nil else { return }
        var next = configuration
        next.layers = [configuration.selectedLayer]
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
