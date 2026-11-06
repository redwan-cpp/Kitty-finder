import Foundation

/// Every location Kitty Finder reads or writes.
///
/// The VFS cache lives in Application Support, not ~/Library/Caches: it holds
/// edits that have not been uploaded yet, and macOS may purge Caches.
public struct Paths: Sendable {
    public let appSupport: URL
    public let logs: URL
    public let mountRoot: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(home: home, name: "Kitty Finder")
    }

    init(home: URL, name: String) {
        appSupport = home.appending(path: "Library/Application Support/\(name)", directoryHint: .isDirectory)
        logs = home.appending(path: "Library/Logs/\(name)", directoryHint: .isDirectory)
        mountRoot = home.appending(path: name, directoryHint: .isDirectory)
    }

    /// Where the app kept its files while it was called KittyDock.
    public static func legacy(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Paths {
        Paths(home: home, name: "KittyDock")
    }

    /// Moves settings, sign-ins, cache and logs from the KittyDock locations,
    /// and removes the old, now empty, drives folder. Run before anything is mounted.
    public func migrate(from old: Paths) {
        let fm = FileManager.default
        for (from, to) in [(old.appSupport, appSupport), (old.logs, logs)]
        where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: from, to: to)
        }
        // Old mount folders are empty when nothing is mounted. rmdir only removes
        // empty directories, so nothing with files in it can be deleted here.
        if let folders = try? fm.contentsOfDirectory(at: old.mountRoot, includingPropertiesForKeys: nil) {
            for folder in folders where !MountTable.isMounted(folder.path) {
                rmdir(folder.path)
            }
        }
        rmdir(old.mountRoot.path)
    }

    public var rcloneConfig: URL { appSupport.appending(path: "rclone.conf") }
    public var accountsFile: URL { appSupport.appending(path: "accounts.json") }
    public var settingsFile: URL { appSupport.appending(path: "settings.json") }

    public func cacheDir(for id: String) -> URL {
        appSupport.appending(path: "cache/\(id)", directoryHint: .isDirectory)
    }

    public func metaDir(for id: String) -> URL {
        appSupport.appending(path: "meta/\(id)", directoryHint: .isDirectory)
    }

    public func logFile(for id: String) -> URL {
        logs.appending(path: "\(id).log")
    }

    public func createBaseDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupport, logs, mountRoot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupport.path)
    }
}
