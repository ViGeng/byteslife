/// The metric families ByteLife tracks. The first five are the flagship channels of the meter and the
/// Double-Entry ledger; `auxiliary` is the catch-all for the accessory sensors (energy, files, and the
/// like) that book to the store but never appear as a meter channel or a ledger account.
public enum MetricFamily: String, CaseIterable, Sendable {
    case ai
    case network
    case disk
    case screen
    case input
    case auxiliary

    public var displayName: String {
        switch self {
        case .ai: return "AI"
        case .network: return "Network"
        case .disk: return "Disk"
        case .screen: return "Screen"
        case .input: return "Input"
        case .auxiliary: return "Auxiliary"
        }
    }
}
