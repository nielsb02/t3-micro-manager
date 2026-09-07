import SwiftUI
import WLKit

@MainActor final class CmuxWorkspaceLoader: ObservableObject {
    @Published private(set) var workspaces: [AgentSession] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published private var revision = 0

    func refresh() { revision += 1 }

    func requestID(for settings: SessionConfiguration) -> String {
        [settings.selectedLayerID, settings.provider.rawValue, settings.cmux.cliPath,
         settings.cmux.socketPath, String(revision)].joined(separator: "\n")
    }

    func load(_ settings: SessionConfiguration, using bridge: BridgeController) async {
        workspaces = []; error = nil; isLoading = false
        guard settings.provider == .cmux else { return }
        isLoading = true
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            let result = try await bridge.cmuxWorkspaces(using: settings)
            try Task.checkCancellation()
            workspaces = result
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
