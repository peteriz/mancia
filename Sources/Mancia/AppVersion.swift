import Foundation

/// The app's version, resolved from the bundle rather than a Swift literal.
///
/// `Support/Info.plist` is the single source of truth: the release workflow
/// rewrites `CFBundleShortVersionString`/`CFBundleVersion` from the git tag, and
/// `scripts/make_app.sh` copies that plist into the bundle. Hardcoding the
/// version here is what let the About panel drift to 0.1.0 while the shipped
/// bundle said 0.2.2, so this file deliberately contains no version number.
enum AppVersion {
    /// Shown when running unbundled (`swift run Mancia`), where there is no
    /// Info.plist to read. Deliberately not a number, so it can never drift.
    static let unbundled = "dev"

    /// The marketing version (`CFBundleShortVersionString`).
    static var short: String { short(from: Bundle.main.infoDictionary) }

    /// The string the About panel shows: the marketing version, plus the build
    /// number in parentheses when the two differ.
    static var displayString: String { displayString(from: Bundle.main.infoDictionary) }

    static func short(from info: [String: Any]?) -> String {
        value(info, "CFBundleShortVersionString") ?? unbundled
    }

    static func build(from info: [String: Any]?) -> String? {
        value(info, "CFBundleVersion")
    }

    static func displayString(from info: [String: Any]?) -> String {
        let short = short(from: info)
        guard let build = build(from: info), build != short else { return short }
        return "\(short) (\(build))"
    }

    /// A non-empty string for `key`, treating whitespace-only values as missing.
    private static func value(_ info: [String: Any]?, _ key: String) -> String? {
        guard let raw = info?[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
