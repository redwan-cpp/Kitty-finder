import Foundation

/// Every location Kitty Finder reads or writes.
///
/// The VFS cache lives in Application Support, not ~/Library/Caches: it holds
/// edits that have not been uploaded yet, and macOS may purge Caches.
public struct Paths: Sendable {
    public let appSupport: URL
    public let logs: URL
    public private(set) var mountRoot: URL

    /// `drivesFolder` is where drives appear; nil means ~/Kitty Finder.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, drivesFolder: String? = nil) {
        self.init(home: home, name: "Kitty Finder")
        if let drivesFolder, !drivesFolder.isEmpty {
            mountRoot = URL(fileURLWithPath: drivesFolder, isDirectory: true)
        }
    }

    init(home: URL, name: String) {
        appSupport = home.appending(path: "Library/Application Support/\(name)", directoryHint: .isDirectory)
        logs = home.appending(path: "Library/Logs/\(name)", directoryHint: .isDirectory)
        mountRoot = home.appending(path: name, directoryHint: .isDirectory)
    }

    /// The default drives folder, ~/Kitty Finder.
    public static func defaultDrivesFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        Paths(home: home).mountRoot
    }

    /// Why `folder` can't hold the drives, or nil if it can.
    ///
    /// Folders that something else syncs are refused: putting the drives there
    /// could make iCloud (Desktop & Documents), or another cloud app, copy the
    /// whole cloud drive back onto the Mac and up again.
    public func drivesFolderProblem(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = folder.standardizedFileURL.path
        func inside(_ base: URL) -> Bool {
            let b = base.standardizedFileURL.path
            return path == b || path.hasPrefix(b + "/")
        }
        if inside(home.appending(path: "Library")) {
            if inside(home.appending(path: "Library/Mobile Documents")) { return "This folder is in iCloud Drive." }
            if inside(home.appending(path: "Library/CloudStorage")) { return "This folder belongs to another cloud app." }
            return "Choose a folder outside your Library folder."
        }
        if inside(appSupport) { return "This is Kitty Finder's own data folder." }
        if path == home.standardizedFileURL.path || path == "/" { return "Choose or create a folder for the drives, not your whole home folder." }
        // Drives must live on the Mac's own disk: a network drive or an external disk
        // that isn't there at startup would stop them mounting.
        for mounted in MountTable.mountedPaths() where !["/", "/System/Volumes/Data"].contains(mounted) {
            if path == mounted || path.hasPrefix(mounted + "/") {
                return "Choose a folder on this Mac's own disk, not on another drive."
            }
        }
        if (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            return "This folder is synced with iCloud (Desktop & Documents in iCloud)."
        }
        if (try? folder.resourceValues(forKeys: [.isWritableKey]))?.isWritable == false {
            return "Kitty Finder can't create folders here."
        }
        return nil
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

    /// What was downloaded for an account's offline folders.
    public func offlineManifest(for id: String) -> URL {
        appSupport.appending(path: "offline/\(id).json")
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
