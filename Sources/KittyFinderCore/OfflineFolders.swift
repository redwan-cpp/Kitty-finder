import Foundation

/// Size and modification time of a file, to notice when it changed.
public struct FileStamp: Codable, Equatable, Sendable {
    public var size: Int64
    public var modified: Double

    public init(size: Int64, modified: Double) {
        self.size = size
        self.modified = modified
    }
}

/// What was downloaded at the last offline sync of one account, keyed by
/// drive-relative file path.
public struct OfflineManifest: Codable, Equatable, Sendable {
    public var files: [String: FileStamp] = [:]

    public init(files: [String: FileStamp] = [:]) { self.files = files }

    /// Files in `current` that are new or changed since this manifest.
    public func changed(in current: [String: FileStamp]) -> [String] {
        current.filter { files[$0.key] != $0.value }.map(\.key).sorted()
    }
}

public enum OfflineFolders {
    /// The account and drive-relative path for a folder Finder handed us, or nil
    /// if it isn't on one of Kitty Finder's drives. "" is the drive itself.
    public static func locate(_ url: URL, in drives: [(id: String, root: URL)]) -> (id: String, path: String)? {
        let path = url.standardizedFileURL.path
        for drive in drives {
            let root = drive.root.standardizedFileURL.path
            if path == root { return (drive.id, "") }
            if path.hasPrefix(root + "/") { return (drive.id, String(path.dropFirst(root.count + 1))) }
        }
        return nil
    }

    /// Adds `folder` to `folders`, dropping folders it contains and ignoring it if
    /// an existing folder already contains it.
    public static func adding(_ folder: String, to folders: [String]) -> [String] {
        if folders.contains(where: { contains($0, folder) }) { return folders }
        return (folders.filter { !contains(folder, $0) } + [folder]).sorted()
    }

    /// True if `parent` is `child` or one of its ancestors ("" contains everything).
    public static func contains(_ parent: String, _ child: String) -> Bool {
        parent.isEmpty || child == parent || child.hasPrefix(parent + "/")
    }
}
