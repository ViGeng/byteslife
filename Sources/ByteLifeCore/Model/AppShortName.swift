/// Derives a short, human display name from an application bundle identifier, purely and without a
/// locale. The `focus` table stores bundle ids (e.g. "com.apple.Safari"); every surface that shows an
/// app — the panel's top-app chip, the Back Office Focus Account, and the receipt's top-app line —
/// renders the last dot-delimited component ("Safari"), so the derivation lives here once rather than
/// being reinvented per surface. A historical read never has the live app around to ask for its name,
/// so this stays a pure string transform covered by `swift test`.
public enum AppShortName {
    /// The bundle id's last dot-delimited component, or the whole trimmed string when it carries no dot.
    /// A blank id reads as "Unknown", so a surface never prints an empty app name.
    public static func short(bundleID: String) -> String {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Unknown" }
        let last = trimmed.split(separator: ".").last.map(String.init)
        return last?.isEmpty == false ? last! : trimmed
    }
}
