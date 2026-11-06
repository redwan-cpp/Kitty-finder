import Foundation
import Testing
@testable import KittyFinderCore

// Command Line Tools ship Swift Testing but not XCTest, so these use Swift Testing.

@Suite struct MountArgumentsTests {
    let paths = Paths(home: URL(fileURLWithPath: "/Users/test"))
    let account = Account(id: "abc123", provider: .googleDrive, email: "me@example.com")

    @Test func nfsmountArguments() {
        let config = MountConfig(account: account, paths: paths, cacheLimitBytes: 5_368_709_120, rcPort: 5599)
        let args = MountArguments.nfsmount(config)

        #expect(Array(args.prefix(3)) == ["nfsmount", "kd-abc123:", "/Users/test/Kitty Finder/Google Drive (me@example.com)"])
        #expect(args.contains("locallocks"), "locallocks fixes Finder copies (EPERM on xattrs)")
        #expect(value(after: "--nfs-apple-meta-dir", in: args) == "/Users/test/Library/Application Support/Kitty Finder/meta/abc123")
        #expect(value(after: "--vfs-cache-mode", in: args) == "full")
        // A bare number would mean KiB to rclone, so the size must carry a unit
        #expect(value(after: "--vfs-cache-max-size", in: args) == "5368709120B")
        #expect(value(after: "--cache-dir", in: args) == "/Users/test/Library/Application Support/Kitty Finder/cache/abc123")
        #expect(value(after: "--rc-addr", in: args) == "127.0.0.1:5599")
        #expect(value(after: "--volname", in: args) == "Google Drive (me@example.com)")
        // Secrets travel in the environment, never in arguments
        #expect(!args.contains { $0.contains("rc-pass") || $0.contains("rc-user") || $0.contains("password") })
    }

    @Test func tunedVersusBaseline() {
        let config = MountConfig(account: account, paths: paths, cacheLimitBytes: 1 << 30, rcPort: 1)
        let tuned = MountArguments.nfsmount(config)
        #expect(tuned.contains("rsize=1048576") && tuned.contains("wsize=1048576"))
        #expect(value(after: "--dir-cache-time", in: tuned) == "1000h")
        #expect(tuned.contains("--vfs-refresh"))
        #expect(!tuned.contains("--vfs-read-chunk-streams"), "measured slower: delays a file's first bytes")
        #expect(value(after: "--vfs-write-back", in: tuned) == "5s")
        #expect(value(after: "--transfers", in: tuned) == "8")
        #expect(value(after: "--drive-pacer-min-sleep", in: tuned) == "10ms")
        // Long listing cache is only safe with change polling on
        #expect(value(after: "--poll-interval", in: tuned) == "15s")

        let baseline = MountArguments.nfsmount(config, tuning: .baseline, extra: ["--foo"])
        #expect(!baseline.contains { $0.hasPrefix("rsize=") })
        #expect(value(after: "--dir-cache-time", in: baseline) == "5m")
        #expect(!baseline.contains("--vfs-refresh") && !baseline.contains("--vfs-read-chunk-streams"))
        #expect(value(after: "--vfs-write-back", in: baseline) == "5s")
        #expect(value(after: "--poll-interval", in: baseline) == "1m")
        #expect(baseline.last == "--foo")
        // Safety-critical flags are present either way
        for args in [tuned, baseline] {
            #expect(args.contains("locallocks") && args.contains("--nfs-apple-meta-dir"))
            #expect(args.contains("--links"), "folders with symlinks must copy in")
            #expect(args.contains("--drive-skip-gdocs=false") && value(after: "--drive-export-formats", in: args) == "webloc")
            #expect(value(after: "--vfs-cache-mode", in: args) == "full")
        }
    }

    @Test func environment() {
        let env = MountArguments.environment(configPassword: "pw", rcUser: "u", rcPass: "p")
        #expect(env["RCLONE_CONFIG_PASS"] == "pw")
        #expect(env["RCLONE_RC_USER"] == "u")
        #expect(env["RCLONE_RC_PASS"] == "p")
        #expect(env["RCLONE_ASK_PASSWORD"] == "false")
        #expect(MountArguments.environment(configPassword: "pw")["RCLONE_RC_PASS"] == nil)
    }

    @Test func cacheSplit() {
        let gib: Int64 = 1_073_741_824
        #expect(MountArguments.perAccountCacheBytes(totalGB: 10, accounts: 1) == 10 * gib)
        #expect(MountArguments.perAccountCacheBytes(totalGB: 10, accounts: 2) == 5 * gib)
        #expect(MountArguments.perAccountCacheBytes(totalGB: 10, accounts: 0) == 10 * gib)
        #expect(MountArguments.perAccountCacheBytes(totalGB: 1, accounts: 4) == gib / 2, "minimum 512 MiB each")
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

@Suite struct ParsingTests {
    @Test func authorizeToken() throws {
        let output = """
        2026/11/06 11:00:00 NOTICE: Make sure your Redirect URL is set to "http://127.0.0.1:53682/" in your custom config.
        2026/11/06 11:00:00 NOTICE: If your browser doesn't open automatically go to the following link: http://127.0.0.1:53682/auth?state=Ab-c_9
        2026/11/06 11:00:00 NOTICE: Log in and authorize rclone for access
        Paste the following into your remote machine --->
        {"access_token":"ya29.x","token_type":"Bearer","refresh_token":"1//y","expiry":"2026-11-06T12:00:00Z"}
        <---End paste
        """
        let token = try #require(AuthorizeOutput.token(in: output))
        #expect(token == #"{"access_token":"ya29.x","token_type":"Bearer","refresh_token":"1//y","expiry":"2026-11-06T12:00:00Z"}"#)
        #expect(AuthorizeOutput.accessToken(fromTokenJSON: token) == "ya29.x")
        #expect(AuthorizeOutput.signInURL(in: output)?.absoluteString == "http://127.0.0.1:53682/auth?state=Ab-c_9")
        #expect(AuthorizeOutput.token(in: "no token here") == nil)
        #expect(AuthorizeOutput.signInURL(in: "nothing") == nil)
    }

    @Test func lastErrorLine() {
        let output = """
        2026/11/06 11:00:00 INFO  : starting
        2026/11/06 11:00:01 ERROR : drive: couldn't connect: token expired
        2026/11/06 11:00:02 INFO  : exiting
        """
        #expect(Rclone.lastErrorLine(output) == "drive: couldn't connect: token expired")
        #expect(Rclone.lastErrorLine("plain failure") == "plain failure")
        #expect(Rclone.lastErrorLine("") == nil)
    }

    @Test func vfsStats() throws {
        let json = """
        {"diskCache":{"bytesUsed":1048576,"erroredFiles":1,"files":3,"hashType":0,"outOfSpace":false,
         "path":"/x","pathMeta":"/y","uploadsInProgress":1,"uploadsQueued":2},"fs":"kd-a:","inUse":1}
        """
        let stats = try JSONDecoder().decode(VFSStats.self, from: Data(json.utf8))
        #expect(stats.bytesUsed == 1_048_576)
        #expect(stats.files == 3)
        #expect(stats.erroredFiles == 1)
        #expect(stats.pendingUploads == 3)
        #expect(try JSONDecoder().decode(VFSStats.self, from: Data("{}".utf8)) == VFSStats())
    }

    @Test func createDriveArguments() {
        let args = RemoteArguments.createDrive(name: "kd-a", client: OAuthClient(id: "id", secret: "s"),
                                               token: "{}", configPath: "/c.conf")
        #expect(Array(args.prefix(4)) == ["config", "create", "kd-a", "drive"])
        for expected in ["client_id=id", "client_secret=s", "scope=drive", "export_formats=webloc", "token={}",
                         "config_refresh_token=false", "config_change_team_drive=false", "--non-interactive"] {
            #expect(args.contains(expected), "\(expected)")
        }
    }

    @Test func oauthClientResolve() {
        var settings = AppSettings()
        settings.googleClientID = "id"
        settings.googleClientSecret = "secret"
        #expect(OAuthClient.resolve(settings: settings) == OAuthClient(id: "id", secret: "secret"))
        settings.googleClientSecret = "  "
        #expect(OAuthClient.resolve(settings: settings, bundle: Bundle(path: "/") ?? .main) == nil)
    }
}

@Suite struct LocalStateTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "kd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @Test func jsonFileRoundTrip() throws {
        let file = JSONFile<[Account]>(dir.appending(path: "sub/accounts.json"))
        #expect(try file.load() == nil)
        let accounts = [Account(provider: .googleDrive, email: "a@b.c"), Account(provider: .googleDrive, email: "d@e.f", enabled: false)]
        try file.save(accounts)
        #expect(try file.load() == accounts)
    }

    @Test func accountNames() {
        let account = Account(id: "x", provider: .googleDrive, email: "a/b:c@d.e")
        #expect(account.remoteName == "kd-x")
        #expect(account.mountPath(in: Paths(home: URL(fileURLWithPath: "/h"))).lastPathComponent == "Google Drive (a-b-c@d.e)")
        #expect(Account.newID().count == 10)
    }

    @Test func cacheInspector() throws {
        let meta = dir.appending(path: "vfsMeta/kd-a/folder")
        let data = dir.appending(path: "vfs/kd-a/folder")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: data.appending(path: "f.bin"))
        try Data(#"{"ModTime":"2026-01-01T00:00:00Z","Size":100000,"Dirty":false}"#.utf8).write(to: meta.appending(path: "f.bin"))
        #expect(!CacheInspector.hasUnuploadedChanges(cacheDir: dir))
        #expect(CacheInspector.bytesUsed(cacheDir: dir) >= 100_000)

        try Data(#"{"Size":5,"Dirty":true}"#.utf8).write(to: meta.appending(path: "g.txt"))
        #expect(CacheInspector.hasUnuploadedChanges(cacheDir: dir))
        #expect(!CacheInspector.hasUnuploadedChanges(cacheDir: dir.appending(path: "missing")))
    }

    @Test func migrateFromKittyDock() throws {
        let fm = FileManager.default
        let old = Paths.legacy(home: dir), new = Paths(home: dir)
        try fm.createDirectory(at: old.appSupport.appending(path: "cache/x"), withIntermediateDirectories: true)
        try Data("conf".utf8).write(to: old.rcloneConfig)
        try fm.createDirectory(at: old.logs, withIntermediateDirectories: true)
        try fm.createDirectory(at: old.mountRoot.appending(path: "Google Drive (a@b.c)"), withIntermediateDirectories: true)

        new.migrate(from: old)
        #expect(try String(contentsOf: new.rcloneConfig, encoding: .utf8) == "conf")
        #expect(fm.fileExists(atPath: new.appSupport.appending(path: "cache/x").path))
        #expect(fm.fileExists(atPath: new.logs.path))
        #expect(!fm.fileExists(atPath: old.appSupport.path))
        #expect(!fm.fileExists(atPath: old.mountRoot.path), "empty old drives folder is removed")
        #expect(new.mountRoot.lastPathComponent == "Kitty Finder")
    }

    @Test func migrateNeverDeletesFiles() throws {
        let fm = FileManager.default
        let old = Paths.legacy(home: dir), new = Paths(home: dir)
        let keep = old.mountRoot.appending(path: "Google Drive (a@b.c)/my file.txt")
        try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: keep)
        // A newer install already exists: the old one must not overwrite it
        try fm.createDirectory(at: new.appSupport, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: new.rcloneConfig)
        try fm.createDirectory(at: old.appSupport, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.rcloneConfig)

        new.migrate(from: old)
        #expect(try String(contentsOf: keep, encoding: .utf8) == "mine")
        #expect(try String(contentsOf: new.rcloneConfig, encoding: .utf8) == "new")
        #expect(fm.fileExists(atPath: old.rcloneConfig.path))
    }

    @Test func mountTable() {
        #expect(MountTable.isMounted("/"))
        #expect(!MountTable.isMounted(dir.path))
    }

    @Test func freePort() throws {
        let port = try #require(RemoteControl.freePort())
        #expect(port > 1024)
    }
}

@Suite struct UnmountTests {
    @Test func forceUnmountOfUnmountedPathIsImmediate() async {
        let start = Date()
        #expect(await MountTable.forceUnmount("/tmp/kitty-finder-not-mounted-\(UUID().uuidString)"))
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func processWait() async throws {
        let quick = Process(), slow = Process()
        quick.executableURL = URL(fileURLWithPath: "/bin/sleep"); quick.arguments = ["0.2"]
        slow.executableURL = URL(fileURLWithPath: "/bin/sleep"); slow.arguments = ["30"]
        try quick.run(); try slow.run()
        #expect(await ProcessWait.untilExited([quick.processIdentifier], timeout: 5).isEmpty)
        #expect(await ProcessWait.untilExited([slow.processIdentifier], timeout: 0.3) == [slow.processIdentifier])
        slow.terminate()
    }

    /// The real failure: the engine dies and leaves a dead NFS mount behind.
    /// Needs the patched rclone (scripts/build-rclone.sh); skipped without it.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: UnmountTests.rclone)))
    func deadMountIsClearedWithinTimeLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kf-dead-\(UUID().uuidString)")
        let remote = dir.appending(path: "remote"), mount = dir.appending(path: "mnt")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = Process()
        engine.executableURL = URL(fileURLWithPath: Self.rclone)
        engine.arguments = ["nfsmount", remote.path, mount.path, "--config", "/dev/null", "-o", "locallocks",
                            "--vfs-cache-mode", "full", "--cache-dir", dir.appending(path: "cache").path]
        engine.standardOutput = FileHandle.nullDevice
        engine.standardError = FileHandle.nullDevice
        try engine.run()
        // Deliberately the /var/… form: isMounted must still match the table's /private/var/…
        let path = mount.path
        for _ in 0..<50 where !MountTable.isMounted(path) { try await Task.sleep(for: .milliseconds(100)) }
        try #require(MountTable.isMounted(path), "engine didn't mount")

        kill(engine.processIdentifier, SIGKILL) // dies without unmounting
        let start = Date()
        let cleared = await MountTable.forceUnmount(path, timeout: 10)
        #expect(Date().timeIntervalSince(start) < 12, "must give up within its time limit")
        #expect(cleared && !MountTable.isMounted(path))
    }

    static let rclone = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "build/rclone").path
}

@Suite struct ProcessTests {
    let shell = Rclone(binary: URL(fileURLWithPath: "/bin/sh"))

    @Test func runCapturesOutputAndStatus() async throws {
        let result = try await shell.run(["-c", "echo out; echo err >&2; exit 3"], environment: [:])
        #expect(result.status == 3)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test func runStreamsOutput() async throws {
        let seen = Seen()
        _ = try await shell.run(["-c", "echo first; sleep 0.2; echo second"], environment: [:]) { seen.set($0) }
        #expect(seen.value == "first\nsecond\n")
    }

    @Test func checkThrowsOnFailure() async {
        await #expect(throws: RcloneError.failed("boom")) {
            try await shell.check(["-c", "echo '2026/11/06 10:00:00 ERROR : boom' >&2; exit 1"], environment: [:])
        }
    }

    @Test func cancelTerminatesProcess() async throws {
        let start = Date()
        let task = Task { try await shell.run(["-c", "sleep 30"], environment: [:]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        #expect(throws: (any Error).self) { try result.get() }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let result = try await shell.run(["-c", "head -c 1000000 /dev/zero | tr '\\0' a"], environment: [:])
        #expect(result.stdout.count == 1_000_000)
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func set(_ s: String) { lock.withLock { text = s } }
}
