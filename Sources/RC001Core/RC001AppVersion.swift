import Foundation

public struct RC001AppVersion: Equatable, Sendable {
    public let release: String
    public let build: String?

    public init(infoDictionary: [String: Any]?) {
        release = Self.nonEmptyString(
            infoDictionary?["CFBundleShortVersionString"]
        ) ?? "开发版"
        build = Self.nonEmptyString(infoDictionary?["CFBundleVersion"])
    }

    public init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary)
    }

    public var displayText: String {
        guard let build else { return "版本 \(release)" }
        return "版本 \(release)（构建 \(build)）"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
