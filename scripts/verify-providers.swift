import Foundation
@testable import WLKit

enum FixtureFailure: Error { case offline }

@MainActor class FixtureProvider: SessionProvider {
    var acknowledgementMode: SessionAcknowledgementMode = .local
    let requiresEmulator = true
    var snapshot = [AgentSession(id: "same-id", title: "Session", status: .done, completionID: "turn-1")]
    var listCalls = 0
    var opened: [String] = []
    var listHandler: (() async throws -> [AgentSession])?
    var openHandler: (() async throws -> Void)?

    func listSessions() async throws -> [AgentSession] {
        listCalls += 1
        if let listHandler { return try await listHandler() }
        return snapshot
    }

    func openSession(_ session: AgentSession) async throws {
        opened.append(session.id)
        try await openHandler?()
    }
}

@MainActor final class InputFixtureProvider: FixtureProvider, SessionInputProvider {
    let inputCapabilities = SessionInputCapabilities(
        acceptsText: true, actions: [SessionAction(id: "inspect", title: "Inspect session")])
    var inputs: [(SessionInput, String)] = []

    func sendInput(_ input: SessionInput, to session: AgentSession) async throws {
        inputs.append((input, session.id))
    }
}

@main struct VerifyProviders {
    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.contains("micro-provider-verify.") == true,
                     "Run through scripts/verify-providers.sh to isolate settings and emulator backups.")
        try pinsAndLegacyConfiguration()
        try await previewConnectionReuse()
        try await providerOrdering()
        try await lifetimeAndAcknowledgements()
        try await nativeAcknowledgements()
        try await optionalInputs()
        try await lateOpen(fails: false)
        try await lateOpen(fails: true)
        try await stopDrainsRefresh()
        print("PASS: provider lifecycle, completion revisions, native read state, pins, input capabilities and connection races")
    }

    static func pinsAndLegacyConfiguration() throws {
        let legacy = Data(#"{"provider":"t3","pinnedSessions":{"0":"t3-session"}}"#.utf8)
        var settings = try JSONDecoder().decode(SessionConfiguration.self, from: legacy)
        precondition(settings.pinnedSessions == [0: "t3-session"])
        settings.provider = .herdr
        precondition(settings.pinnedSessions.isEmpty)
        settings.pinnedSessions = [0: "herdr-session"]
        settings.provider = .t3
        precondition(settings.pinnedSessions == [0: "t3-session"])
        let restored = try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(settings))
        precondition(restored == settings)
        settings = restored
        settings.provider = .herdr
        precondition(settings.pinnedSessions == [0: "herdr-session"])
        print("Legacy pins migrate and each provider retains its own selections.")
    }

    @MainActor static func lifetimeAndAcknowledgements() async throws {
        try SessionConfiguration().save()
        let provider = FixtureProvider()
        var constructions = 0
        let bridge = BridgeController(providerFactory: { _ in constructions += 1; return provider })
        await bridge.startDemo()
        let count = constructions
        precondition(bridge.lastError == nil)
        for _ in 0..<3 { await bridge.forceRepaint() }
        precondition(constructions == count, "Polling must reuse the provider connection")
        await bridge.focusSession(bridge.sessions[0])
        precondition(bridge.sessions[0].status == .idle)
        provider.snapshot[0].title = "Renamed"
        provider.snapshot[0].updatedAt = "metadata-change"
        await bridge.forceRepaint()
        precondition(bridge.sessions[0].status == .idle, "Metadata edits must not create a new unread completion")
        provider.snapshot[0].completionID = "turn-2"
        await bridge.forceRepaint()
        precondition(bridge.sessions[0].status == .done, "A completion between polls must become unread")
        await bridge.focusSession(bridge.sessions[0])
        var settings = bridge.configuration
        settings.selection = .recent
        await bridge.saveConfiguration(settings)
        precondition(constructions == count && bridge.sessions[0].status == .idle,
                     "Changing key selection must not replace the connection or reset read state")

        provider.listHandler = { throw FixtureFailure.offline }
        await bridge.forceRepaint()
        precondition(bridge.sessions[0].status == .unknown)
        provider.listHandler = nil
        await bridge.forceRepaint()
        precondition(bridge.sessions[0].status == .idle, "A reconnect to the same completion retains acknowledgement")

        provider.snapshot.append(provider.snapshot[0])
        await bridge.forceRepaint()
        precondition(bridge.sessions.count == 1 && bridge.sessions[0].status == .unknown)
        precondition(bridge.lastError?.contains("duplicate") == true)
        provider.snapshot.removeLast()
        provider.snapshot[0].status = .working
        settings.driveAmbient = true
        await bridge.saveConfiguration(settings)
        let pad = bridge.emulator!
        let physicalKey = bridge.assignments.first(where: { $0.value == "same-id" })!.key
        let light = pad.light(forPhysicalKey: physicalKey)!
        precondition(pad.ambientZone.speed == light.speed && pad.ambientZone.effect == light.effect,
                     "Ambient and individual keys must receive the same working pulse")
        await bridge.stop()
        precondition(!pad.light(forPhysicalKey: physicalKey)!.isLit)
        print("Connection reuse, rapid completions, reconnects, invalid snapshots and ambient effects passed.")
    }

    @MainActor static func previewConnectionReuse() async throws {
        try SessionConfiguration().save()
        var instances: [FixtureProvider] = []
        let bridge = BridgeController(providerFactory: { _ in
            let provider = FixtureProvider()
            provider.openHandler = { [weak provider] in
                precondition((provider?.listCalls ?? 0) > 0, "Open must reuse the tested provider connection")
            }
            instances.append(provider)
            return provider
        })
        var settings = bridge.configuration
        settings.t3.baseURL = "http://127.0.0.1:4242"
        let sessions = try await bridge.testConnection(settings)
        _ = try await bridge.testConnection(settings)
        try await bridge.openSession(sessions[0], using: settings)
        precondition(instances.count == 2 && instances[0].listCalls == 0 && instances[0].opened.isEmpty)
        precondition(instances[1].listCalls == 2 && instances[1].opened == [sessions[0].id])
        precondition(bridge.configuration != settings && bridge.sessions.isEmpty)
        print("Testing and opening a draft reuse an isolated preview connection.")
    }

    @MainActor static func providerOrdering() async throws {
        try SessionConfiguration().save()
        let provider = FixtureProvider()
        provider.snapshot = [
            AgentSession(id: "a", title: "A", status: .working, providerOrder: 1),
            AgentSession(id: "b", title: "B", status: .blocked, providerOrder: 0),
            AgentSession(id: "history", title: "History", status: .done)
        ]
        let bridge = BridgeController(providerFactory: { _ in provider })
        await bridge.startDemo()
        var settings = bridge.configuration
        settings.provider = .t3; settings.selection = .providerOrder
        settings.sessionKeys = [0, 1]; settings.pinnedSessions = [0: "history"]
        await bridge.saveConfiguration(settings)
        precondition(bridge.lastError == nil && bridge.keymapReady && bridge.layerActive)
        precondition(bridge.sessions.map(\.id) == ["b", "a"] && bridge.assignments == [0: "b", 1: "a"])
        provider.snapshot[0].providerOrder = 0; provider.snapshot[1].providerOrder = 1
        await bridge.forceRepaint()
        precondition(bridge.sessions.map(\.id) == ["a", "b"] && bridge.assignments == [0: "a", 1: "b"])
        bridge.emulator!.press(0)
        try await until { !provider.opened.isEmpty }
        precondition(provider.opened == ["a"], "After a drag, the physical key opens the newly displayed session")
        provider.snapshot[0].providerOrder = nil
        await bridge.forceRepaint()
        precondition(bridge.sessions.map(\.id) == ["b"] && bridge.assignments == [0: "b"])
        precondition(bridge.configuration.pinnedSessions == [0: "history"], "Local pins remain saved")
        await bridge.stop()
        print("Provider rearrangement updates the menu, keys and physical press routing together.")
    }

    @MainActor static func nativeAcknowledgements() async throws {
        try SessionConfiguration().save()
        let provider = FixtureProvider()
        provider.acknowledgementMode = .provider
        let bridge = BridgeController(providerFactory: { _ in provider })
        await bridge.startDemo()
        await bridge.focusSession(bridge.sessions[0])
        precondition(bridge.sessions[0].status == .done, "Native provider read state is authoritative")
        provider.snapshot[0].status = .idle
        await bridge.forceRepaint()
        precondition(bridge.sessions[0].status == .idle)
        await bridge.stop()
    }

    @MainActor static func optionalInputs() async throws {
        try SessionConfiguration().save()
        let provider = InputFixtureProvider()
        let readOnly = FixtureProvider()
        let bridge = BridgeController(providerFactory: { $0.provider == .herdr ? readOnly : provider })
        await bridge.startDemo()
        precondition(bridge.inputCapabilities.acceptsText)
        try await bridge.sendInput(.text("draft only"), to: "same-id")
        try await bridge.sendInput(.action("inspect"), to: "same-id")
        precondition(provider.inputs.count == 2 && provider.inputs.allSatisfy { $0.1 == "same-id" })
        do {
            try await bridge.sendInput(.action("approve"), to: "same-id")
            preconditionFailure("Unadvertised actions must be refused")
        } catch SessionProviderError.unsupportedInput {}
        do {
            try await bridge.sendInput(.text("draft"), to: "missing")
            preconditionFailure("Unknown session must be refused")
        } catch SessionProviderError.unavailableSession {}
        precondition(provider.inputs.count == 2)
        var settings = bridge.configuration
        settings.provider = .herdr
        await bridge.saveConfiguration(settings)
        precondition(!bridge.inputCapabilities.acceptsText && bridge.inputCapabilities.actions.isEmpty)
        do {
            try await bridge.sendInput(.text("draft"), to: "same-id")
            preconditionFailure("Read/open-only providers must refuse inputs")
        } catch SessionProviderError.unsupportedInput {}
        await bridge.stop()
        print("Text and advertised actions route only to the selected capable provider.")
    }

    @MainActor static func lateOpen(fails: Bool) async throws {
        try SessionConfiguration().save()
        let old = FixtureProvider(), next = FixtureProvider()
        let bridge = BridgeController(providerFactory: { $0.provider == .herdr ? next : old })
        await bridge.startDemo()
        var pending: CheckedContinuation<Void, Error>?
        old.openHandler = { try await withCheckedThrowingContinuation { pending = $0 } }
        let session = bridge.sessions[0]
        let opening = Task { await bridge.focusSession(session) }
        try await until { pending != nil }
        var settings = bridge.configuration
        settings.provider = .herdr
        await bridge.saveConfiguration(settings)
        if fails { pending!.resume(throwing: FixtureFailure.offline) }
        else { pending!.resume() }
        await opening.value
        precondition(bridge.sessions[0].status == .done && bridge.lastError == nil,
                     "Old opening results must not acknowledge or report errors on a new connection")
        precondition(next.opened.isEmpty)
        await bridge.stop()
    }

    @MainActor static func stopDrainsRefresh() async throws {
        try SessionConfiguration().save()
        let old = FixtureProvider(), next = FixtureProvider()
        next.snapshot[0].title = "New provider"
        let bridge = BridgeController(providerFactory: { $0.provider == .herdr ? next : old })
        await bridge.startDemo()
        var pending: CheckedContinuation<[AgentSession], Error>?
        old.listHandler = { try await withCheckedThrowingContinuation { pending = $0 } }
        let polling = Task { await bridge.forceRepaint() }
        try await until { pending != nil }
        var settings = bridge.configuration
        settings.provider = .herdr
        var saved = false
        let saving = Task { await bridge.saveConfiguration(settings); saved = true }
        try await until { bridge.isBusy }
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(!saved && next.listCalls == 0, "Stop must drain the old refresh before replacing a connection")
        pending!.resume(returning: old.snapshot)
        await polling.value
        await saving.value
        precondition(bridge.sessions[0].title == "New provider" && bridge.lastError == nil)
        await bridge.stop()
        print("Delayed openings and polls cannot mutate a replacement connection.")
    }

    @MainActor static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out waiting for the fixture")
    }
}
