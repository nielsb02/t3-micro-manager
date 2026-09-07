import SwiftUI
import WLKit

struct CmuxViewSelector: View {
    var scope: CmuxSessionScope
    var workspaceID: String
    var workspaces: [AgentSession]
    var isLoading: Bool
    var error: String?
    var compact = false
    var onSelect: (CmuxSessionScope, String) -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Picker("Show on keys", selection: Binding(
                    get: { scope },
                    set: { value in
                        let workspace = workspaceID.isEmpty ? workspaces.first?.id ?? "" : workspaceID
                        onSelect(value, workspace)
                    }
                )) {
                    Text("Workspaces").tag(CmuxSessionScope.workspaces)
                    Text("Within workspace").tag(CmuxSessionScope.workspace)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if compact, scope == .workspaces { refreshButton }
            }

            if scope == .workspace {
                HStack(spacing: 6) {
                    Picker("Workspace", selection: Binding(
                        get: { workspaceID },
                        set: { onSelect(.workspace, $0) }
                    )) {
                        Text("Choose a workspace…").tag("")
                        if !workspaceID.isEmpty, !workspaces.contains(where: { $0.id == workspaceID }) {
                            Text("Unavailable workspace (saved)").tag(workspaceID)
                        }
                        ForEach(workspaces) { workspace in
                            Text(workspace.title).tag(workspace.id)
                        }
                    }
                    .labelsHidden()
                    refreshButton
                }
            } else if !compact {
                HStack {
                    Text("Each key opens a workspace and shows its agents' combined status.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    refreshButton
                }
            }
            if scope == .workspace, !compact {
                Text("Keys show recent terminals and browser tabs in this workspace. Pin favorites below to keep their keys fixed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isLoading)
        .help("Refresh cmux workspaces")
        .accessibilityLabel("Refresh cmux workspaces")
    }
}
