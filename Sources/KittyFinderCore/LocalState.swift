import Foundation
import Security

/// Mount table lookups that never touch the mounted file system, so a dead
/// NFS server can't hang the caller.
public enum MountTable {
    public static func isMounted(_ path: String) -> Bool {
        mountedPaths().contains(URL(fileURLWithPath: path).standardizedFileURL.path)
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

    /// Force-unmounts a stale mount (for example after rclone crashed).
    @discardableResult
    public static func forceUnmount(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["unmount", "force", path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
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
