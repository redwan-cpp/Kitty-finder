import Foundation
import KittyFinderCore

/// Downloads the files in one account's offline folders, so they open without
/// an internet connection. The engine keeps pinned files from being cleared;
/// this reads each new or changed file once so the engine downloads it.
@Observable @MainActor
final class OfflineSync {
    enum Status: Equatable, Sendable {
        case waiting(String)
        case downloading(done: Int, total: Int)
        case upToDate
        case failed(String)
    }

    /// Per offline folder (drive-relative path).
    private(set) var status: [String: Status] = [:]
    /// Total size of each folder's files.
    private(set) var bytes: [String: Int64] = [:]
    /// Called when a folder has finished downloading new files.
    @ObservationIgnored var onReady: ((String) -> Void)?

    private let manifestFile: URL
    private var task: Task<Void, Never>?
    private var generation = 0

    init(manifestFile: URL) { self.manifestFile = manifestFile }

    /// Brings `folders` up to date. With `blocked` set, nothing downloads and
    /// folders that aren't ready yet show it as the reason.
    func run(folders: [String], root: URL, blocked: Status?, keepFreeBytes: Int64, cacheVolume: URL) {
        cancel()
        let gen = generation
        for folder in Array(status.keys) where !folders.contains(folder) {
            status[folder] = nil
            bytes[folder] = nil
        }
        if let blocked {
            for folder in folders where status[folder] != .upToDate { status[folder] = blocked }
            return
        }
        guard !folders.isEmpty else { return }
        for folder in folders where status[folder] == nil { status[folder] = .waiting("Checking…") }
        let manifestFile = manifestFile
        let report: @Sendable (String, Status, Int64?) async -> Void = { [weak self] folder, status, size in
            await self?.report(gen, folder, status, size)
        }
        task = Task.detached(priority: .utility) {
            await Self.work(folders: folders, root: root, keepFreeBytes: keepFreeBytes, cacheVolume: cacheVolume,
                            manifestFile: manifestFile, report: report)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
    }

    /// Forgets what was downloaded, after the downloaded copies were deleted.
    func forget() {
        cancel()
        try? FileManager.default.removeItem(at: manifestFile)
        status = [:]
    }

    private func report(_ gen: Int, _ folder: String, _ new: Status, _ size: Int64?) {
        guard gen == generation else { return }
        if case .downloading(_, let total) = status[folder], total > 0, new == .upToDate { onReady?(folder) }
        status[folder] = new
        if let size { bytes[folder] = size }
    }

    private nonisolated static func work(folders: [String], root: URL, keepFreeBytes: Int64, cacheVolume: URL, manifestFile: URL,
                                         report: @escaping @Sendable (String, Status, Int64?) async -> Void) async {
        let file = JSONFile<OfflineManifest>(manifestFile)
        var manifest = (try? file.load()) ?? OfflineManifest()
        manifest.files = manifest.files.filter { entry in folders.contains { OfflineFolders.contains($0, entry.key) } }
        for folder in folders {
            if Task.isCancelled { break }
            let dir = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
            guard let current = await onQueue({ scan(dir, prefix: folder) }) else {
                await report(folder, .failed("This folder isn't on the drive any more."), nil)
                continue
            }
            for key in Array(manifest.files.keys) where OfflineFolders.contains(folder, key) && current[key] == nil {
                manifest.files[key] = nil
            }
            let size = current.values.reduce(Int64(0)) { $0 + $1.size }
            let changed = manifest.changed(in: current)
            if changed.isEmpty {
                await report(folder, .upToDate, size)
                continue
            }
            let needed = changed.reduce(Int64(0)) { $0 + (current[$1]?.size ?? 0) }
            let free = (try? cacheVolume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? .max
            if free - needed < keepFreeBytes {
                await report(folder, .failed("Not enough space on this Mac: it needs \(ByteFormat.string(needed)), "
                    + "and Kitty Finder keeps \(ByteFormat.string(keepFreeBytes)) free."), size)
                continue
            }
            await report(folder, .downloading(done: 0, total: changed.count), size)
            var done = 0, failures = 0
            await withTaskGroup(of: (String, Bool).self) { group in
                var queue = changed[...]
                func next() -> (@Sendable () async -> (String, Bool))? {
                    guard let path = queue.popFirst() else { return nil }
                    let url = root.appending(path: path)
                    return { (path, await onQueue { download(url) }) }
                }
                for _ in 0..<3 { if let job = next() { group.addTask(operation: job) } }
                while let (path, ok) = await group.next() {
                    done += 1
                    if ok { manifest.files[path] = current[path] } else { failures += 1 }
                    if done % 20 == 0 { try? file.save(manifest) }
                    await report(folder, .downloading(done: done, total: changed.count), nil)
                    if !Task.isCancelled, let job = next() { group.addTask(operation: job) }
                }
            }
            try? file.save(manifest)
            if Task.isCancelled { break }
            await report(folder, failures == 0 ? .upToDate
                : .failed("\(failures) file\(failures == 1 ? "" : "s") couldn't download. Kitty Finder tries again later."), nil)
        }
    }

    /// Runs blocking file work off Swift's shared threads.
    private nonisolated static func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: work()) }
        }
    }

    /// Every file in `dir`, keyed by its drive-relative path. nil if `dir` is gone.
    private nonisolated static func scan(_ dir: URL, prefix: String) -> [String: FileStamp]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return nil }
        let base = dir.standardizedFileURL.path
        var files: [String: FileStamp] = [:]
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue } // kept on this Mac anyway
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            files[prefix.isEmpty ? relative : prefix + "/" + relative] = FileStamp(
                size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return files
    }

    /// Reads a file to the end, which makes the engine download all of it.
    private nonisolated static func download(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {}
            return true
        } catch {
            return false
        }
    }
}
