/// The five "byte" metric families ByteLife tracks.
public enum MetricFamily: String, CaseIterable, Sendable {
    case ai
    case network
    case disk
    case screen
    case input

    public var displayName: String {
        switch self {
        case .ai: return "AI"
        case .network: return "Network"
        case .disk: return "Disk"
        case .screen: return "Screen"
        case .input: return "Input"
        }
    }
}
