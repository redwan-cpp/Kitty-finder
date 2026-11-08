import Foundation

/// Keeps each drive's VFS cache in one folder.
///
/// rclone keeps a drive's downloaded copies in `vfs/<name>` and its records of
/// them in `vfsMeta/<name>`. Before 0.2.2 Kitty Finder passed Drive settings as
/// flags, and rclone added a hash of them to the name ("kd-a{C3LU_}"), so each
/// change of settings started a new cache and left the old one behind.
public enum CacheFolders {
    public struct Result: Equatable, Sendable {
        /// Drive-relative paths of edits that never uploaded, saved to `recoverTo`.
        public var recovered: [String]
        /// Space freed by deleting the folders left behind.
        public var removedBytes: Int64
    }

    /// Makes `remoteName` the drive's only cache folder: the most recently used
    /// folder is renamed to it and the others are deleted. Edits in those that
    /// never uploaded are first copied to `recoverTo` (never overwriting a file);
    /// if that fails, nothing is deleted. Call only while the drive's engine is stopped.
    public static func consolidate(cacheDir: URL, remoteName: String, recoverTo: URL) throws -> Result {
        let fm = FileManager.default
        let data = cacheDir.appending(path: "vfs"), meta = cacheDir.appending(path: "vfsMeta")
        func belongs(_ name: String) -> Bool {
            name == remoteName || (name.hasPrefix(remoteName + "{") && name.hasSuffix("}"))
        }
        let names = Set([data, meta].flatMap { (try? fm.contentsOfDirectory(atPath: $0.path)) ?? [] }.filter(belongs))
        guard names.contains(where: { $0 != remoteName }) else { return Result(recovered: [], removedBytes: 0) }
        let live = names.max { lastUsed(meta.appending(path: $0)) < lastUsed(meta.appending(path: $1)) }!
        let leftovers = names.filter { $0 != live }.sorted()

        var recovered: [String] = []
        for name in leftovers {
            for path in dirtyFiles(in: meta.appending(path: name)) {
                let source = data.appending(path: name).appending(path: path)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = unused(recoverTo.appending(path: path))
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                recovered.append(path)
            }
        }
        var removed: Int64 = 0
        for name in leftovers {
            for folder in [data.appending(path: name), meta.appending(path: name)] where fm.fileExists(atPath: folder.path) {
                removed += size(of: folder)
                try fm.removeItem(at: folder)
            }
        }
        if live != remoteName {
            for base in [data, meta] where fm.fileExists(atPath: base.appending(path: live).path) {
                try fm.moveItem(at: base.appending(path: live), to: base.appending(path: remoteName))
            }
        }
        return Result(recovered: recovered.sorted(), removedBytes: removed)
    }

    /// Files under `folder`, keyed by their path relative to it.
    private static func files(in folder: URL) -> [(path: String, url: URL)] {
        let base = folder.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [(String, URL)] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let full = url.resolvingSymlinksInPath().path
            if full.hasPrefix(base + "/") { out.append((String(full.dropFirst(base.count + 1)), url)) }
        }
        return out
    }

    /// When rclone last wrote any record in this folder (it rewrites them on use).
    private static func lastUsed(_ metaFolder: URL) -> Date {
        let dates = files(in: metaFolder).compactMap {
            try? $0.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return dates.max() ?? (try? metaFolder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    private static func dirtyFiles(in metaFolder: URL) -> [String] {
        struct Meta: Decodable { let Dirty: Bool? }
        return files(in: metaFolder).filter { file in
            guard let data = try? Data(contentsOf: file.url) else { return false }
            return (try? JSONDecoder().decode(Meta.self, from: data))?.Dirty == true
        }.map(\.path)
    }

    private static func size(of folder: URL) -> Int64 {
        files(in: folder).reduce(0) {
            $0 + Int64((try? $1.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
    }

    /// `url`, or "name 2.ext", "name 3.ext"… if it's taken.
    private static func unused(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        for n in 2... {
            let candidate = url.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
