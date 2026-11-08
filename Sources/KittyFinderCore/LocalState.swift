import Foundation
import Security

/// Mount table lookups that never touch the mounted file system, so a dead
/// NFS server can't hang the caller.
public enum MountTable {
    public static func isMounted(_ path: String) -> Bool {
        let mounted = mountedPaths()
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if mounted.contains(trimmed) { return true }
        // The table has real paths (/tmp and /var live under /private). Resolve only the
        // parent: resolving the mount point itself would touch the mount and could hang.
        let url = URL(fileURLWithPath: trimmed)
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { return false }
        defer { free(parent) }
        let real = String(cString: parent)
        return mounted.contains((real == "/" ? "" : real) + "/" + url.lastPathComponent)
    }

    public static func mountedPaths() -> Set<String> {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var paths = Set<String>()
        for i in 0..<Int(count) {
            var entry = buffer[i]
            let path = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            paths.insert(path)
        }
        return paths
    }

    /// Unmounts `path`, forcibly if needed, and reports whether it is unmounted afterwards.
    ///
    /// Tries a plain `umount`, then `umount -f` (the kernel drops the mount at once,
    /// even if its server is gone), then `diskutil unmount force`. Unmounting NFS can
    /// block indefinitely, so this never waits longer than `timeout`; a command that is
    /// still blocked is left to finish on its own.
    @discardableResult
    public static func forceUnmount(_ path: String, timeout: TimeInterval = 10) async -> Bool {
        for command in [["/sbin/umount"], ["/sbin/umount", "-f"], ["/usr/sbin/diskutil", "unmount", "force"]] {
            guard isMounted(path) else { return true }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: command[0])
            p.arguments = Array(command.dropFirst()) + [path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { continue }
            let deadline = Date().addingTimeInterval(timeout / 3)
            while p.isRunning && isMounted(path) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return !isMounted(path)
    }
}

/// Waits for processes to exit, without blocking a thread.
public enum ProcessWait {
    /// True if `pid` is still running.
    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Waits until none of `pids` is running, or `timeout` passes. Returns the ones still running.
    public static func untilExited(_ pids: [pid_t], timeout: TimeInterval) async -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        var alive = pids.filter(isAlive)
        while !alive.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            alive = alive.filter(isAlive)
        }
        return alive
    }
}

/// Facts about an account's local VFS cache, read from disk.
public enum CacheInspector {
    /// Bytes used by cached file contents.
    public static func bytesUsed(cacheDir: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: cacheDir.appending(path: "vfs"),
                                         includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// True if any cached file has edits that haven't been uploaded yet.
    /// rclone records this as `"Dirty": true` in the file's vfsMeta JSON.
    public static func hasUnuploadedChanges(cacheDir: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: cacheDir.appending(path: "vfsMeta"),
                                                          includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        struct Meta: Decodable { let Dirty: Bool? }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            if (try? JSONDecoder().decode(Meta.self, from: data))?.Dirty == true { return true }
        }
        return false
    }

    /// True if the engine holds all of a drive file (`path`, drive-relative) on this
    /// Mac, according to its record in `metaRoot` (the engine's `pathMeta`).
    public static func isFullyCached(_ path: String, metaRoot: URL) -> Bool {
        struct Meta: Decodable {
            struct Range: Decodable { let Pos: Int64; let Size: Int64 }
            let Size: Int64
            let Rs: [Range]?
            let Fingerprint: String?
            let Dirty: Bool?
        }
        guard let data = try? Data(contentsOf: metaRoot.appending(path: path)),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return false }
        // Without a fingerprint or local edits, the record is a placeholder with no data
        guard meta.Dirty == true || !(meta.Fingerprint ?? "").isEmpty else { return false }
        var covered: Int64 = 0
        for range in (meta.Rs ?? []).sorted(by: { $0.Pos < $1.Pos }) {
            if range.Pos > covered { return false }
            covered = max(covered, range.Pos + range.Size)
        }
        return covered >= meta.Size
    }
}

public enum KeychainLookup: Equatable, Sendable {
    case found(String)
    /// No item exists: safe to create a new one.
    case notFound
    /// The item may exist but couldn't be read (access denied or cancelled, keychain locked).
    /// Never treat this as "missing": that would throw away a working config.
    case failed(OSStatus)
}

/// Stores the rclone config password in the login keychain.
///
/// Reading can block for as long as macOS shows its "allow access" prompt,
/// so callers must not call these on the main thread.
public enum Keychain {
    public static let service = "Kitty Finder"
    /// The service name used while the app was called KittyDock.
    public static let legacyService = "KittyDock"

    public static func lookup(account: String, service: String = Keychain.service) -> KeychainLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else { return .failed(status) }
            return .found(password)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    public static func setPassword(_ password: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = service // the name macOS shows in its prompt
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RcloneError.failed("Couldn't save to the keychain (error \(status)).")
        }
    }

    public static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
