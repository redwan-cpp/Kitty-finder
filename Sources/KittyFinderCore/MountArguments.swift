import Foundation

/// Everything needed to start one account's mount.
public struct MountConfig: Equatable, Sendable {
    public var remoteName: String
    public var mountPath: String
    public var configPath: String
    public var cacheDir: String
    public var metaDir: String
    public var logFile: String
    public var volumeName: String
    public var cacheLimitBytes: Int64
    public var rcPort: Int

    public init(account: Account, paths: Paths, cacheLimitBytes: Int64, rcPort: Int) {
        remoteName = account.remoteName
        mountPath = account.mountPath(in: paths).path
        configPath = paths.rcloneConfig.path
        cacheDir = paths.cacheDir(for: account.id).path
        metaDir = paths.metaDir(for: account.id).path
        logFile = paths.logFile(for: account.id).path
        volumeName = account.title
        self.cacheLimitBytes = cacheLimitBytes
        self.rcPort = rcPort
    }
}

public enum MountArguments {
    /// Arguments for `rclone nfsmount`, proven in the spike (spike/README.md).
    ///
    /// Secrets are not passed here: the config password and the remote-control
    /// credentials go in the environment (`environment(...)`), because any
    /// local user can read another process's arguments.
    public static func nfsmount(_ c: MountConfig) -> [String] {
        [
            "nfsmount", "\(c.remoteName):", c.mountPath,
            "--config", c.configPath,
            // rclone's NFS server has no lock manager; without this macOS can't
            // store extended attributes and Finder copies fail with EPERM.
            "-o", "locallocks",
            // Patched rclone: keep ._* and .DS_Store on this Mac, never upload them.
            "--nfs-apple-meta-dir", c.metaDir,
            // Files download on open; edits are cached and uploaded in the background.
            "--vfs-cache-mode", "full",
            "--vfs-cache-max-size", "\(c.cacheLimitBytes)B",
            "--vfs-cache-max-age", "720h",
            "--vfs-write-back", "5s",
            "--cache-dir", c.cacheDir,
            "--dir-cache-time", "5m",
            "--poll-interval", "1m",
            "--volname", c.volumeName,
            "--rc", "--rc-addr", "127.0.0.1:\(c.rcPort)",
            "--log-file", c.logFile,
            "--log-level", "INFO",
            "--log-file-max-size", "10M",
            "--log-file-max-backups", "3",
        ]
    }

    /// Environment for any rclone call. `rcUser`/`rcPass` are only needed for mounts.
    public static func environment(configPassword: String, rcUser: String? = nil, rcPass: String? = nil) -> [String: String] {
        var env: [String: String] = [
            "RCLONE_CONFIG_PASS": configPassword,
            "RCLONE_ASK_PASSWORD": "false",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        if let rcUser, let rcPass {
            env["RCLONE_RC_USER"] = rcUser
            env["RCLONE_RC_PASS"] = rcPass
        }
        return env
    }

    /// Splits a total cache limit evenly between the enabled accounts (minimum 512 MiB each).
    public static func perAccountCacheBytes(totalGB: Int, accounts: Int) -> Int64 {
        let total = Int64(max(totalGB, 1)) * 1_073_741_824
        return max(total / Int64(max(accounts, 1)), 536_870_912)
    }
}
