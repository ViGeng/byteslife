import SwiftUI
import ByteLifeCore

/// The menubar app itself: a single window-style MenuBarExtra hosting the compact dashboard panel.
/// The view model is a StateObject so it lives for the whole app session and drives the polling timer.
struct ByteLifeApplication: App {
    @StateObject private var viewModel = DashboardViewModel(coordinator: .shared)

    var body: some Scene {
        MenuBarExtra("ByteLife", systemImage: "chart.bar.doc.horizontal") {
            MenuBarView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact panel: one row per metric family plus a footer with a Quit control. Deliberately plain;
/// the Ledger visual skin is applied in a later stage.
struct MenuBarView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ForEach(viewModel.rows) { row in
                FamilyRowView(row: row) { viewModel.requestInputPermission() }
                Divider().padding(.leading, 12)
            }

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }
}

/// One family row: name and availability badge on top, formatted value (and optional detail) below.
private struct FamilyRowView: View {
    let row: FamilyRow
    /// Invoked when the user taps the needs-permission affordance; raises the Input Monitoring prompt.
    let onRequestPermission: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.family.displayName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                badge
            }
            Text(row.value)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
            if let detail = row.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var badge: some View {
        switch row.availability {
        case .running:
            // A subtle green dot; running is the quiet, expected state.
            Circle().fill(.green).frame(width: 6, height: 6)
        case .needsPermission:
            Menu {
                Button("Grant Permission…", action: onRequestPermission)
                Button("Open Input Monitoring Settings…") {
                    PermissionsHint.openInputMonitoringSettings()
                }
            } label: {
                Label("Needs permission", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.yellow)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        case .sourceMissing:
            Text("not reporting")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .disabled:
            Text("off")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
