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
        #expect(!args.contains { $0.hasPrefix("--vfs-pin") }, "no offline folders, no pins")
        // A stalled request (e.g. right after Wi-Fi reconnects) must not hang a drive for rclone's default 5 minutes
        #expect(value(after: "--timeout", in: args) == "1m")
        #expect(value(after: "--contimeout", in: args) == "15s")
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
        #expect(MountTuning.tuned.driveSettings == ["chunk_size": "32M", "pacer_min_sleep": "10ms", "pacer_burst": "200"])
        #expect(MountTuning.baseline.driveSettings.values.allSatisfy { $0.isEmpty }, "baseline: rclone's defaults")
        // Long listing cache is only safe with change polling on
        #expect(value(after: "--poll-interval", in: tuned) == "15s")

        let baseline = MountArguments.nfsmount(config, tuning: .baseline, extra: ["--foo"])
        #expect(!baseline.contains { $0.hasPrefix("rsize=") })
        #expect(value(after: "--dir-cache-time", in: baseline) == "5m")
        #expect(!baseline.contains("--vfs-refresh") && !baseline.contains("--vfs-read-chunk-streams"))
        #expect(value(after: "--vfs-write-back", in: baseline) == "5s")
        #expect(tuned.filter { $0 == "--poll-interval" }.count == 1, "one poll interval, from the user's settings")
        #expect(baseline.last == "--foo")
        // Safety-critical flags are present either way
        for args in [tuned, baseline] {
            #expect(args.contains("locallocks") && args.contains("--nfs-apple-meta-dir"))
            #expect(args.contains("--links"), "folders with symlinks must copy in")
            // As flags, Drive settings change the engine's name for the drive, and with it
            // its cache folder: downloads, offline folders and unuploaded edits get left behind.
            #expect(!args.contains { $0.hasPrefix("--drive-") }, "Drive settings belong in rclone.conf")
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
        #expect(stats.metaPath == "/y", "where the engine keeps its cache records, to check offline files")
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

    @Test func updateDriveSettingsArguments() {
        let args = RemoteArguments.update(name: "kd-a", settings: ["skip_gdocs": "true", "chunk_size": ""], configPath: "/c.conf")
        #expect(args == ["config", "update", "kd-a", "chunk_size=", "skip_gdocs=true",
                         "config_refresh_token=false", "config_change_team_drive=false", "--non-interactive",
                         "--config", "/c.conf"], "never asks to sign in again or pick a shared drive")
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

@Suite struct SettingsTests {
    @Test func oldSettingsFileStillLoads() throws {
        let old = #"{"cacheLimitGB": 25, "googleClientID": "id", "googleClientSecret": "s"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(s.cacheLimitGB == 25 && s.googleClientID == "id")
        #expect(s.keepFreeGB == 5 && s.keepCopiesDays == 30 && s.pollSeconds == 15)
        #expect(s.menuBarIcon == .twoTone && s.showGoogleDocs && s.checkForUpdates && s.drivesFolder == nil)
    }

    @Test func outOfRangeValuesAreClamped() throws {
        let odd = #"{"cacheLimitGB": 0, "keepFreeGB": 999, "keepCopiesDays": 0, "pollSeconds": 7, "menuBarIcon": "rainbow"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(odd.utf8))
        #expect(s.cacheLimitGB == 1 && s.keepFreeGB == 200 && s.keepCopiesDays == 1 && s.pollSeconds == 15)
        #expect(s.menuBarIcon == .twoTone)
    }

    @Test func settingsRoundTrip() throws {
        var s = AppSettings()
        s.menuBarIcon = .cloud; s.drivesFolder = "/Users/x/Drives"; s.pollSeconds = 300; s.lastUpdateCheck = Date(timeIntervalSince1970: 100)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func oldAccountsFileStillLoads() throws {
        let old = #"[{"id": "abc", "provider": "googleDrive", "email": "a@b.c", "enabled": false}]"#
        let accounts = try JSONDecoder().decode([Account].self, from: Data(old.utf8))
        #expect(accounts.first?.displayName == nil && accounts.first?.offlineFolders == [] && accounts.first?.enabled == false)
    }

    @Test func customDriveNames() {
        var a = Account(id: "x", provider: .googleDrive, email: "me@school.edu")
        let paths = Paths(home: URL(fileURLWithPath: "/h"))
        #expect(a.title == "Google Drive (me@school.edu)")
        a.displayName = "  School Drive  "
        #expect(a.title == "School Drive")
        #expect(a.mountPath(in: paths).path == "/h/Kitty Finder/School Drive")
        a.displayName = "   "
        #expect(a.title == a.defaultTitle)
        a.displayName = ".secret/stuff"
        #expect(a.mountPath(in: paths).lastPathComponent == "_secret-stuff", "no hidden or nested folders")
    }

    @Test func mountOptionsReachTheEngine() {
        var s = AppSettings()
        s.keepFreeGB = 0; s.keepCopiesDays = 7; s.pollSeconds = 60; s.showGoogleDocs = false
        let paths = Paths(home: URL(fileURLWithPath: "/h"))
        let config = MountConfig(account: Account(id: "a", provider: .googleDrive, email: "e"), paths: paths, cacheLimitBytes: 1 << 30, rcPort: 1)
        let args = MountArguments.nfsmount(config, options: s.mountOptions)
        #expect(value(after: "--vfs-cache-max-age", in: args) == "168h")
        #expect(value(after: "--poll-interval", in: args) == "60s")
        #expect(!args.contains("--vfs-cache-min-free-space"), "0 GB means off")
        #expect(s.mountOptions.driveSettings == ["skip_gdocs": "true", "export_formats": "webloc"])
        #expect(MountOptions().driveSettings == ["skip_gdocs": "false", "export_formats": "webloc"])
        s.keepFreeGB = 5
        #expect(value(after: "--vfs-cache-min-free-space", in: MountArguments.nfsmount(config, options: s.mountOptions)) == "5368709120B")
    }

    @Test func drivesFolderGuard() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "kf-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let ok = home.appending(path: "Drives")
        try FileManager.default.createDirectory(at: ok, withIntermediateDirectories: true)
        #expect(paths.drivesFolderProblem(ok, home: home) == nil)
        #expect(paths.drivesFolderProblem(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/X"), home: home) != nil)
        #expect(paths.drivesFolderProblem(home.appending(path: "Library/CloudStorage/GoogleDrive-a/My Drive"), home: home) != nil)
        #expect(paths.drivesFolderProblem(paths.appSupport.appending(path: "x"), home: home) != nil)
        #expect(paths.drivesFolderProblem(home, home: home) != nil)
        #expect(paths.drivesFolderProblem(URL(fileURLWithPath: "/"), home: home) != nil)
        #expect(Paths(home: home, drivesFolder: ok.path).mountRoot.path == ok.path)
        #expect(Paths(home: home, drivesFolder: nil).mountRoot.lastPathComponent == "Kitty Finder")
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

@Suite struct UpdateTests {
    @Test func versionComparison() {
        #expect(UpdateChecker.isNewer("v0.2.0", than: "0.1.0"))
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateChecker.isNewer("v0.1.0", than: "0.2.0"))
        #expect(!UpdateChecker.isNewer("0.2", than: "0.2.0"))
        #expect(UpdateChecker.isNewer("0.2.1-beta", than: "0.2.0"))
    }

    @Test func releaseParsingPicksThePublicZip() throws {
        let json = #"""
        {"tag_name": "v0.2.0", "name": "Kitty Finder 0.2.0", "body": "notes", "html_url": "https://github.com/o/r/releases/tag/v0.2.0",
         "draft": false, "prerelease": false, "assets": [
          {"name": "KittyFinder-0.2.0.zip", "size": 1, "browser_download_url": "https://x/a.zip", "digest": "sha256:aa"},
          {"name": "KittyFinder-0.2.0-public.zip", "size": 2, "browser_download_url": "https://x/b.zip", "digest": "sha256:bb"}]}
        """#
        let r = try JSONDecoder().decode(Release.self, from: Data(json.utf8))
        #expect(r.version == "0.2.0")
        #expect(r.installAsset?.name == "KittyFinder-0.2.0-public.zip")
        #expect(r.installAsset?.digest == "sha256:bb")
    }

    @Test func checksumVerification() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "kf-sum-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let hello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(try UpdateChecker.sha256(of: file) == hello)
        #expect(try UpdateChecker.matches(file, digest: "sha256:" + hello))
        #expect(try UpdateChecker.matches(file, digest: "sha256:" + hello.uppercased()), "hex case doesn't matter")
        #expect(try !UpdateChecker.matches(file, digest: "sha256:00"))
        #expect(try !UpdateChecker.matches(file, digest: nil), "no digest means not verified")
    }
}

@Suite struct OfflineFolderTests {
    @Test func manifestFindsNewAndChangedFiles() {
        let before = OfflineManifest(files: ["a.txt": FileStamp(size: 1, modified: 1), "b.txt": FileStamp(size: 2, modified: 2)])
        let now: [String: FileStamp] = ["a.txt": FileStamp(size: 1, modified: 1), "b.txt": FileStamp(size: 3, modified: 2),
                                        "c.txt": FileStamp(size: 1, modified: 1)]
        #expect(before.changed(in: now) == ["b.txt", "c.txt"])
        #expect(OfflineManifest().changed(in: now).count == 3)
    }

    @Test func locateFolderOnADrive() {
        let drives = [(id: "a", root: URL(fileURLWithPath: "/h/Kitty Finder/School")),
                      (id: "b", root: URL(fileURLWithPath: "/h/Kitty Finder/School Drive"))]
        #expect(OfflineFolders.locate(URL(fileURLWithPath: "/h/Kitty Finder/School Drive/Notes/2026"), in: drives)! == ("b", "Notes/2026"))
        #expect(OfflineFolders.locate(URL(fileURLWithPath: "/h/Kitty Finder/School"), in: drives)! == ("a", ""))
        #expect(OfflineFolders.locate(URL(fileURLWithPath: "/h/Documents/x"), in: drives) == nil)
    }

    @Test func addingFoldersAvoidsOverlap() {
        #expect(OfflineFolders.adding("A/B", to: ["A"]) == ["A"], "already inside a kept folder")
        #expect(OfflineFolders.adding("A", to: ["A/B", "C"]) == ["A", "C"], "replaces folders it contains")
        #expect(OfflineFolders.adding("AB", to: ["A"]) == ["A", "AB"], "a name prefix isn't a parent")
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

@Suite struct DiagnosticsTests {
    @Test func removesPersonalDetails() {
        let home = "/Users/someone"
        let names = ["Google Drive (me@example.com)", "Work"]
        let text = Diagnostics.redact(
            "Couldn't create /Users/someone/Kitty Finder/Work/Taxes 2025: permission denied", home: home, names: names)
        #expect(text == "Couldn't create ~/Kitty Finder/<drive>/<path>: permission denied")
        #expect(Diagnostics.redact("ERROR : Photos/beach.jpg: upload failed", home: home, names: names)
                == "ERROR : <file>: upload failed")
        #expect(Diagnostics.redact("token for other@gmail.com expired", home: home, names: names)
                == "token for <email> expired")
        #expect(Diagnostics.redact("Google Drive (me@example.com) stopped", home: home, names: names) == "<drive> stopped")
    }

    @Test func issueLinkHasOnlyVersions() throws {
        let url = try #require(Diagnostics.issueURL(repository: "owner/repo", appVersion: "0.2.0", macOS: "15.1", engine: "v1.75.2"))
        #expect(url.absoluteString.hasPrefix("https://github.com/owner/repo/issues/new?body="))
        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
        #expect(body.contains("Kitty Finder 0.2.0 · macOS 15.1 · engine v1.75.2"))
    }
}

@Suite struct OfflineCacheTests {
    let account = Account(id: "abc123", provider: .googleDrive, email: "me@example.com")
    let paths = Paths(home: URL(fileURLWithPath: "/Users/test"))

    @Test func offlineFoldersArePinnedFromTheStart() {
        // The engine clears its cache as soon as it starts, so pins must be in its arguments
        let config = MountConfig(account: account, paths: paths, cacheLimitBytes: 1 << 30, rcPort: 1,
                                 pinnedFolders: ["Work/Taxes", "-odd name", ""])
        let args = MountArguments.nfsmount(config)
        #expect(args.filter { $0.hasPrefix("--vfs-pin") } == ["--vfs-pin=Work/Taxes", "--vfs-pin=-odd name", "--vfs-pin="])
    }

    @Test func fullyCachedFiles() throws {
        let meta = FileManager.default.temporaryDirectory.appending(path: "kf-meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: meta) }
        func write(_ path: String, _ json: String) throws {
            let url = meta.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url)
        }
        try write("a/whole.txt", #"{"Size":10,"Rs":[{"Pos":0,"Size":4},{"Pos":4,"Size":6}],"Fingerprint":"f","Dirty":false}"#)
        try write("a/part.txt", #"{"Size":10,"Rs":[{"Pos":0,"Size":4}],"Fingerprint":"f","Dirty":false}"#)
        try write("a/gap.txt", #"{"Size":10,"Rs":[{"Pos":0,"Size":4},{"Pos":5,"Size":5}],"Fingerprint":"f"}"#)
        try write("a/empty.txt", #"{"Size":0,"Rs":[],"Fingerprint":"f"}"#)
        try write("a/placeholder.txt", #"{"Size":0,"Rs":[],"Fingerprint":""}"#)
        try write("a/edited.txt", #"{"Size":3,"Rs":[{"Pos":0,"Size":3}],"Fingerprint":"","Dirty":true}"#)
        #expect(CacheInspector.isFullyCached("a/whole.txt", metaRoot: meta))
        #expect(!CacheInspector.isFullyCached("a/part.txt", metaRoot: meta))
        #expect(!CacheInspector.isFullyCached("a/gap.txt", metaRoot: meta))
        #expect(CacheInspector.isFullyCached("a/empty.txt", metaRoot: meta))
        #expect(!CacheInspector.isFullyCached("a/placeholder.txt", metaRoot: meta), "an entry with no data yet")
        #expect(CacheInspector.isFullyCached("a/edited.txt", metaRoot: meta))
        #expect(!CacheInspector.isFullyCached("a/missing.txt", metaRoot: meta))
    }
}

@Suite struct CacheFolderTests {
    let fm = FileManager.default

    /// A cache folder as rclone lays it out: vfs/<name>/<path> data, vfsMeta/<name>/<path> records.
    private func add(_ cache: URL, _ name: String, _ path: String, contents: String, dirty: Bool = false, age: TimeInterval = 0) throws {
        let data = cache.appending(path: "vfs/\(name)/\(path)"), meta = cache.appending(path: "vfsMeta/\(name)/\(path)")
        for url in [data, meta] { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data(contents.utf8).write(to: data)
        try Data(#"{"Size":\#(contents.utf8.count),"Rs":[{"Pos":0,"Size":\#(contents.utf8.count)}],"Fingerprint":"f","Dirty":\#(dirty)}"#.utf8).write(to: meta)
        let date = Date().addingTimeInterval(-age)
        for url in [data, meta] { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    private func names(_ cache: URL, _ kind: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: cache.appending(path: kind).path)) ?? []).sorted()
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func newestFolderBecomesTheOneFolderAndOldEditsAreSaved() throws {
        let root = fm.temporaryDirectory.appending(path: "kf-cache-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let cache = root.appending(path: "cache"), recovered = root.appending(path: "Recovered Edits/My Drive")
        try add(cache, "kd-a", "stale.txt", contents: "from 0.1.0", age: 3 * 86400)
        try add(cache, "kd-a{OLD}", "notes/todo.txt", contents: "edit that never uploaded", dirty: true, age: 86400)
        try add(cache, "kd-a{OLD}", "photo.jpg", contents: "old download", age: 86400)
        try add(cache, "kd-a{NEW}", "notes/todo.txt", contents: "current", age: 60)
        try add(cache, "kd-a{NEW}", "offline/keep.txt", contents: "offline copy", age: 60)
        try add(cache, "kd-b{XYZ}", "other.txt", contents: "another drive", age: 0)

        let result = try CacheFolders.consolidate(cacheDir: cache, remoteName: "kd-a", recoverTo: recovered)

        #expect(names(cache, "vfs") == ["kd-a", "kd-b{XYZ}"] && names(cache, "vfsMeta") == ["kd-a", "kd-b{XYZ}"],
                "one folder per drive, other drives untouched")
        #expect(read(cache.appending(path: "vfs/kd-a/offline/keep.txt")) == "offline copy", "the newest folder is kept")
        #expect(read(cache.appending(path: "vfsMeta/kd-a/offline/keep.txt")) != nil)
        #expect(read(cache.appending(path: "vfs/kd-a/stale.txt")) == nil, "the stale folder is gone")
        #expect(result.recovered == ["notes/todo.txt"])
        #expect(read(recovered.appending(path: "notes/todo.txt")) == "edit that never uploaded")
        #expect(result.removedBytes > 0)
    }

    @Test func recoveredEditsNeverOverwrite() throws {
        let root = fm.temporaryDirectory.appending(path: "kf-cache-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let cache = root.appending(path: "cache"), recovered = root.appending(path: "Recovered")
        try fm.createDirectory(at: recovered, withIntermediateDirectories: true)
        try Data("saved earlier".utf8).write(to: recovered.appending(path: "a.txt"))
        try add(cache, "kd-a", "keep.txt", contents: "live", age: 0)
        try add(cache, "kd-a{OLD}", "a.txt", contents: "second rescue", dirty: true, age: 100)

        let result = try CacheFolders.consolidate(cacheDir: cache, remoteName: "kd-a", recoverTo: recovered)
        #expect(result.recovered == ["a.txt"])
        #expect(read(recovered.appending(path: "a.txt")) == "saved earlier")
        #expect(read(recovered.appending(path: "a 2.txt")) == "second rescue")
        #expect(names(cache, "vfs") == ["kd-a"])
        #expect(read(cache.appending(path: "vfs/kd-a/keep.txt")) == "live", "already the one folder: kept as is")
    }

    @Test func nothingToDo() throws {
        let root = fm.temporaryDirectory.appending(path: "kf-cache-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let cache = root.appending(path: "cache")
        let empty = try CacheFolders.consolidate(cacheDir: cache, remoteName: "kd-a", recoverTo: root.appending(path: "R"))
        #expect(empty.recovered.isEmpty && empty.removedBytes == 0)
        try add(cache, "kd-a", "x.txt", contents: "x")
        let single = try CacheFolders.consolidate(cacheDir: cache, remoteName: "kd-a", recoverTo: root.appending(path: "R"))
        #expect(single.recovered.isEmpty && single.removedBytes == 0 && names(cache, "vfs") == ["kd-a"])
        #expect(!fm.fileExists(atPath: root.appending(path: "R").path), "no Recovered Edits folder unless something was saved")
    }
}
