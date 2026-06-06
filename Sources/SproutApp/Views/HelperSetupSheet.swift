import ServiceManagement
import SwiftUI

/// Launch-time gate for the privileged loopback helper. Auto-presented from the
/// main window when the helper is not yet `.enabled`, so per-workspace loopback
/// IPs work without the user hunting through Settings. Dismissible ("Later") so
/// unsigned dev builds — where the helper bundle is absent — aren't locked out.
struct HelperSetupSheet: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        // Observe the helper directly: `AppModel` does not republish on the
        // helper's nested `@Published status`, so the status text and auto-close
        // would otherwise go stale.
        HelperSetupContent(helper: app.helper)
    }
}

private struct HelperSetupContent: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var helper: HelperManager
    @State private var helperError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Enable Loopback Helper", systemImage: "network")
                .font(.title3.bold())

            Text(
                "Per-workspace loopback IPs require a signed root helper so each "
                    + "branch can reuse the same internal ports concurrently. "
                    + "Enable it once to use isolated workspaces."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Per-workspace loopback IPs", isOn: enabledBinding)

            Text(HelperManager.label(for: helper.status))
                .font(.caption)
                .foregroundStyle(.secondary)

            if helper.status == .requiresApproval {
                Button("Open Login Items Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .font(.caption)
            }

            if let helperError {
                Text(helperError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440)
        .onAppear { helper.refresh() }
        // Close automatically once the helper is fully enabled.
        .onChange(of: helper.status) { _, newValue in
            if newValue == .enabled { dismiss() }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { helper.status == .enabled },
            set: { on in
                helperError = nil
                do {
                    try on ? helper.install() : helper.uninstall()
                } catch {
                    helperError = "\(error)"
                }
            })
    }
}
