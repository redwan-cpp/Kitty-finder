import Foundation

public enum Provider: String, Codable, Sendable {
    case googleDrive

    /// rclone backend name
    public var backend: String {
        switch self {
        case .googleDrive: return "drive"
        }
    }

    public var displayName: String {
        switch self {
        case .googleDrive: return "Google Drive"
        }
    }
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var provider: Provider
    public var email: String
    public var enabled: Bool

    public init(id: String = Account.newID(), provider: Provider, email: String, enabled: Bool = true) {
        self.id = id
        self.provider = provider
        self.email = email
        self.enabled = enabled
    }

    /// Name of this account's remote in rclone.conf
    public var remoteName: String { "kd-\(id)" }

    /// Shown in the menu and used as the Finder volume and folder name
    public var title: String { "\(provider.displayName) (\(email))" }

    public func mountPath(in paths: Paths) -> URL {
        paths.mountRoot.appending(path: Account.folderName(title), directoryHint: .isDirectory)
    }

    /// A short random id, safe in file names and rclone remote names.
    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    /// Strips characters that can't appear in a folder name.
    static func folderName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

/// User settings, stored as JSON.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Total space local copies may use, shared by all accounts.
    public var cacheLimitGB: Int = 10
    /// Optional Google OAuth client. When empty, the client bundled with the app is used.
    public var googleClientID: String = ""
    public var googleClientSecret: String = ""

    public init() {}

    public static let cacheLimitRange = 1...500
}

/// Reads and writes a Codable value as a JSON file, atomically.
public struct JSONFile<Value: Codable> {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}
