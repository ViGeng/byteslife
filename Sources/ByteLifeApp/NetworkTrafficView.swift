import SwiftUI
import CoreLocation
import ByteLifeCore

struct NetworkTrafficView: View {
    let dayEpoch: Int64
    let store: SampleStore

    @Environment(\.colorScheme) private var scheme
    @State private var rows: [NetworkTraffic] = []
    @State private var readFailed = false
    @StateObject private var permission = WiFiNamePermission()

    private var isToday: Bool { dayEpoch == DayBucket.dayEpoch(for: Date()) }
    private var dim: Color { LatticePalette.dim(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By connection")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if readFailed {
                note("Connection totals are temporarily unavailable.")
            } else if rows.isEmpty {
                note(isToday ? "No connection traffic recorded today." : "No connection details recorded for this day.")
            } else {
                connectionTable
            }

            if isToday {
                permissionControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            load()
            while isToday {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                load()
            }
        }
    }

    private var connectionTable: some View {
        let wifiNetworks = rows.filter {
            if case .wifi = $0.connection { return true }
            return false
        }
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                heading("Received")
                heading("Sent")
                heading("Total")
            }
            if !wifiNetworks.isEmpty {
                trafficRow("Wi-Fi", bytesIn: wifiNetworks.reduce(0) { $0 + $1.bytesIn },
                           bytesOut: wifiNetworks.reduce(0) { $0 + $1.bytesOut })
                ForEach(wifiNetworks) { network in
                    trafficRow(label(for: network.connection), bytesIn: network.bytesIn,
                               bytesOut: network.bytesOut, indented: true)
                }
            }
            ForEach([NetworkConnection.ethernet, .other], id: \.self) { connection in
                if let traffic = rows.first(where: { $0.connection == connection }) {
                    trafficRow(label(for: connection), bytesIn: traffic.bytesIn, bytesOut: traffic.bytesOut)
                }
            }
        }
    }

    private func trafficRow(_ name: String, bytesIn: Int64, bytesOut: Int64, indented: Bool = false) -> some View {
        GridRow {
            Text(name)
                .fontWeight(indented ? .regular : .semibold)
                .foregroundStyle(indented ? dim : LatticePalette.dial(scheme))
                .lineLimit(1)
                .help(name)
                .padding(.leading, indented ? 14 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            amount(bytesIn, label: "Received")
            amount(bytesOut, label: "Sent")
            amount(bytesIn + bytesOut, label: "Total")
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func amount(_ bytes: Int64, label: String) -> some View {
        let formatted = ByteFormatting.bytes(bytes)
        return Text(formatted)
            .monospacedDigit()
            .accessibilityLabel("\(label): \(formatted)")
    }

    private func heading(_ label: String) -> some View {
        note(label.uppercased()).gridColumnAlignment(.trailing)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(dim)
    }

    private func label(for connection: NetworkConnection) -> String {
        switch connection {
        case .wifi(let ssid): return ssid ?? "Unknown Wi-Fi network"
        case .ethernet: return "Ethernet"
        case .other: return "Other interfaces"
        }
    }

    @ViewBuilder
    private var permissionControls: some View {
        switch permission.status {
        case .notDetermined:
            HStack(spacing: 8) {
                Button("Enable Wi-Fi names", action: permission.request)
                note("macOS requires Location Services to read Wi-Fi names.")
            }
            .controlSize(.small)
        case .denied, .restricted:
            HStack(spacing: 8) {
                Button("Open System Settings", action: PermissionsHint.openSystemSettings)
                note("Enable ByteLife under Location Services to see Wi-Fi names.")
            }
            .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func load() {
        do {
            rows = try store.networkTraffic(dayEpoch: dayEpoch)
            readFailed = false
        } catch {
            readFailed = true
        }
    }
}

private final class WiFiNamePermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        status = manager.authorizationStatus
        manager.delegate = self
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
    }
}
