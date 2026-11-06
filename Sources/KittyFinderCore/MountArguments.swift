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

/// Performance settings for a mount. `tuned` is the default; `baseline` is the
/// original setup, kept so the two can be benchmarked (spike/bench.py).
public struct MountTuning: Equatable, Sendable {
    /// NFS read/write size in bytes; nil uses macOS's default (32 KB).
    public var nfsTransferSize: Int?
    /// How long folder listings are trusted. Drive's change feed (polled every
    /// minute) keeps them current, so a long time is safe and makes browsing instant.
    public var dirCacheTime: String
    /// How often to ask Drive for changes made elsewhere (web, phone, other Macs).
    public var pollInterval: String
    /// List the whole drive in the background when mounting.
    public var refreshOnStart: Bool
    /// Parallel download streams per file (0 = rclone's single growing stream).
    public var readChunkStreams: Int
    public var readChunkSize: String
    /// Parallel uploads.
    public var transfers: Int
    /// Google Drive upload chunk size (rclone default 8M).
    public var driveChunkSize: String?
    /// Google Drive request pacing (rclone default 100ms between calls, burst 100).
    public var drivePacerMinSleep: String?
    public var drivePacerBurst: Int?
    /// Delay after a file is closed before it uploads.
    public var writeBack: String

    public static let baseline = MountTuning(
        nfsTransferSize: nil, dirCacheTime: "5m", pollInterval: "1m", refreshOnStart: false,
        readChunkStreams: 0, readChunkSize: "128M", transfers: 4,
        driveChunkSize: nil, drivePacerMinSleep: nil, drivePacerBurst: nil, writeBack: "5s")

    /// Measured on a real Drive (spike/bench-*.json): uploads of many files 2.2× faster,
    /// folders open instantly once listed, changes from elsewhere appear in ~35 s instead
    /// of ~60 s, and Finder↔mount transfers up to 7× faster. Parallel download streams
    /// were tried and dropped: they delayed the first bytes of a file (2.6 s → 7 s).
    public static let tuned = MountTuning(
        nfsTransferSize: 1_048_576, dirCacheTime: "1000h", pollInterval: "15s", refreshOnStart: true,
        readChunkStreams: 0, readChunkSize: "128M", transfers: 8,
        driveChunkSize: "32M", drivePacerMinSleep: "10ms", drivePacerBurst: 200, writeBack: "5s")

    var arguments: [String] {
        var args: [String] = []
        if let size = nfsTransferSize {
            args += ["-o", "rsize=\(size)", "-o", "wsize=\(size)"]
        }
        args += ["--dir-cache-time", dirCacheTime, "--poll-interval", pollInterval]
        if refreshOnStart { args += ["--vfs-refresh"] }
        if readChunkStreams > 0 { args += ["--vfs-read-chunk-streams", "\(readChunkStreams)"] }
        args += ["--vfs-read-chunk-size", readChunkSize, "--transfers", "\(transfers)", "--vfs-write-back", writeBack]
        if let size = driveChunkSize { args += ["--drive-chunk-size", size] }
        if let sleep = drivePacerMinSleep { args += ["--drive-pacer-min-sleep", sleep] }
        if let burst = drivePacerBurst { args += ["--drive-pacer-burst", "\(burst)"] }
        return args
    }
}

public enum MountArguments {
    /// Arguments for `rclone nfsmount`, proven in the spike (spike/README.md).
    ///
    /// Secrets are not passed here: the config password and the remote-control
    /// credentials go in the environment (`environment(...)`), because any
    /// local user can read another process's arguments.
    public static func nfsmount(_ c: MountConfig, tuning: MountTuning = .tuned, extra: [String] = []) -> [String] {
        [
            "nfsmount", "\(c.remoteName):", c.mountPath,
            "--config", c.configPath,
            // rclone's NFS server has no lock manager; without this macOS can't
            // store extended attributes and Finder copies fail with EPERM.
            "-o", "locallocks",
            // Patched rclone: keep ._* and .DS_Store on this Mac, never upload them.
            "--nfs-apple-meta-dir", c.metaDir,
            // Symlinks are stored as small .rclonelink files, so folders containing
            // them can be copied in from the Mac.
            "--links",
            // Google Docs, Sheets and Slides appear as .webloc links that open in the
            // browser, so they can be seen, moved and deleted (and their folders too).
            "--drive-skip-gdocs=false", "--drive-export-formats", "webloc",
            // Files download on open; edits are cached and uploaded in the background.
            "--vfs-cache-mode", "full",
            "--vfs-cache-max-size", "\(c.cacheLimitBytes)B",
            "--vfs-cache-max-age", "720h",
            "--cache-dir", c.cacheDir,
            "--volname", c.volumeName,
            "--rc", "--rc-addr", "127.0.0.1:\(c.rcPort)",
            "--log-file", c.logFile,
            "--log-level", "INFO",
            "--log-file-max-size", "10M",
            "--log-file-max-backups", "3",
        ] + tuning.arguments + extra
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
