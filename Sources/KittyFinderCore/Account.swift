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
    /// Custom name for the drive (Finder folder, volume and menu); nil uses the default.
    public var displayName: String?
    /// Folders kept downloaded for offline use, as paths relative to the drive root.
    public var offlineFolders: [String]

    public init(id: String = Account.newID(), provider: Provider, email: String, enabled: Bool = true,
                displayName: String? = nil, offlineFolders: [String] = []) {
        self.id = id
        self.provider = provider
        self.email = email
        self.enabled = enabled
        self.displayName = displayName
        self.offlineFolders = offlineFolders
    }

    enum CodingKeys: String, CodingKey { case id, provider, email, enabled, displayName, offlineFolders }

    /// Fields added after 0.1.0 are optional in the file, so older accounts.json still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(Provider.self, forKey: .provider)
        email = try c.decode(String.self, forKey: .email)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        offlineFolders = try c.decodeIfPresent([String].self, forKey: .offlineFolders) ?? []
    }

    /// Name of this account's remote in rclone.conf
    public var remoteName: String { "kd-\(id)" }

    /// The default name, used when no custom name is set
    public var defaultTitle: String { "\(provider.displayName) (\(email))" }

    /// Shown in the menu and used as the Finder volume and folder name
    public var title: String {
        let custom = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? defaultTitle : custom
    }

    public func mountPath(in paths: Paths) -> URL {
        paths.mountRoot.appending(path: Account.folderName(title), directoryHint: .isDirectory)
    }

    /// A short random id, safe in file names and rclone remote names.
    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    /// Strips characters that can't appear in a folder name.
    public static func folderName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the drive in Finder
        return cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
    }
}

/// The menu bar icon's look.
public enum MenuBarIconStyle: String, Codable, CaseIterable, Sendable {
    case twoTone, outline, cloud

    public var label: String {
        switch self {
        case .twoTone: return "Two-tone kitty"
        case .outline: return "Outline kitty"
        case .cloud: return "Cloud"
        }
    }
}

/// User settings, stored as JSON. Every field has a default and older files
/// load with the defaults for fields they don't have.
public struct AppSettings: Codable, Equatable, Sendable {
    // General
    public var showWindowAtLaunch = false
    public var menuBarIcon = MenuBarIconStyle.twoTone
    public var showUploadCount = true
    public var notifyUploadProblems = false
    public var notifyOfflineReady = false
    public var notifyUpdates = false

    // Drives
    /// Where drives appear; nil means ~/Kitty Finder.
    public var drivesFolder: String?
    /// Show Google Docs, Sheets and Slides as links that open in the browser.
    public var showGoogleDocs = true

    // Storage
    /// Total space local copies may use, shared by all accounts.
    public var cacheLimitGB = 10
    /// Clear downloaded copies early to keep at least this much free on the Mac (0 = off).
    public var keepFreeGB = 5
    /// Downloaded copies not used for this many days are cleared.
    public var keepCopiesDays = 30

    // Sync
    /// How often to check Google Drive for changes made elsewhere.
    public var pollSeconds = 15

    // Updates
    public var checkForUpdates = true
    public var lastUpdateCheck: Date?

    // Google
    /// Google OAuth client. When empty, the client bundled with the app is used.
    public var googleClientID = ""
    public var googleClientSecret = ""

    public init() {}

    public static let cacheLimitRange = 1...500
    public static let keepFreeRange = 0...200
    public static let keepCopiesRange = 1...365
    public static let pollChoices = [15, 60, 300]

    enum CodingKeys: String, CodingKey {
        case showWindowAtLaunch, menuBarIcon, showUploadCount, notifyUploadProblems, notifyOfflineReady, notifyUpdates
        case drivesFolder, showGoogleDocs, cacheLimitGB, keepFreeGB, keepCopiesDays, pollSeconds
        case checkForUpdates, lastUpdateCheck, googleClientID, googleClientSecret
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        showWindowAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .showWindowAtLaunch) ?? d.showWindowAtLaunch
        menuBarIcon = (try? c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIcon)) ?? d.menuBarIcon
        showUploadCount = try c.decodeIfPresent(Bool.self, forKey: .showUploadCount) ?? d.showUploadCount
        notifyUploadProblems = try c.decodeIfPresent(Bool.self, forKey: .notifyUploadProblems) ?? d.notifyUploadProblems
        notifyOfflineReady = try c.decodeIfPresent(Bool.self, forKey: .notifyOfflineReady) ?? d.notifyOfflineReady
        notifyUpdates = try c.decodeIfPresent(Bool.self, forKey: .notifyUpdates) ?? d.notifyUpdates
        drivesFolder = try c.decodeIfPresent(String.self, forKey: .drivesFolder)
        showGoogleDocs = try c.decodeIfPresent(Bool.self, forKey: .showGoogleDocs) ?? d.showGoogleDocs
        cacheLimitGB = try c.decodeIfPresent(Int.self, forKey: .cacheLimitGB) ?? d.cacheLimitGB
        keepFreeGB = try c.decodeIfPresent(Int.self, forKey: .keepFreeGB) ?? d.keepFreeGB
        keepCopiesDays = try c.decodeIfPresent(Int.self, forKey: .keepCopiesDays) ?? d.keepCopiesDays
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? d.pollSeconds
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        googleClientID = try c.decodeIfPresent(String.self, forKey: .googleClientID) ?? d.googleClientID
        googleClientSecret = try c.decodeIfPresent(String.self, forKey: .googleClientSecret) ?? d.googleClientSecret
        clamp()
    }

    /// Keeps numbers within their ranges (also after editing).
    public mutating func clamp() {
        cacheLimitGB = min(max(cacheLimitGB, Self.cacheLimitRange.lowerBound), Self.cacheLimitRange.upperBound)
        keepFreeGB = min(max(keepFreeGB, Self.keepFreeRange.lowerBound), Self.keepFreeRange.upperBound)
        keepCopiesDays = min(max(keepCopiesDays, Self.keepCopiesRange.lowerBound), Self.keepCopiesRange.upperBound)
        if !Self.pollChoices.contains(pollSeconds) { pollSeconds = 15 }
    }

    /// Settings that are passed to the sync engine; changing them restarts drives.
    public var mountOptions: MountOptions {
        MountOptions(keepFreeBytes: Int64(keepFreeGB) * 1_073_741_824, keepCopiesHours: keepCopiesDays * 24,
                     pollInterval: "\(pollSeconds)s", showGoogleDocs: showGoogleDocs)
    }
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
