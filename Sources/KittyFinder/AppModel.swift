import AppKit
import KittyFinderCore
import Network
import ServiceManagement

enum SignInState: Equatable {
    case idle
    case waitingForBrowser(URL?)
    case finishing
    case failed(String)
}

/// App-wide state: accounts, settings, mounts, offline folders and sign-in.
@Observable @MainActor
final class AppModel {
    private(set) var paths = Paths()
    private(set) var accounts: [Account] = []
    private(set) var settings = AppSettings()
    private(set) var mounts: [String: MountController] = [:]
    private(set) var offlineSyncs: [String: OfflineSync] = [:]
    var signIn: SignInState = .idle
    private(set) var fatalError: String?
    /// True until startup finishes, including any keychain prompt macOS shows.
    private(set) var isStarting = true
    /// True while the Mac has no internet connection.
    private(set) var isOffline = false
    /// The sync engine's version, e.g. "v1.75.2".
    private(set) var engineVersion = ""
    let updater = Updater()
    /// Opens the Settings window; set by the app delegate.
    @ObservationIgnored var openSettingsHandler: ((SettingsTab?) -> Void)?

    private var rclone: Rclone?
    private var configPassword = ""
    private var signInTask: Task<Void, Never>?
    private var observing = false
    private var lastProblem: [String: (message: String, date: Date)] = [:]
    @ObservationIgnored private let network = NWPathMonitor()
    private static let keychainAccount = "rclone-config"

    // MARK: Startup

    /// After a startup failure (for example the keychain prompt was denied).
    func retryStart() async {
        fatalError = nil
        await start()
    }

    func start() async {
        isStarting = true
        defer { isStarting = false }
        // Where drives are mounted is a setting, so read it before cleaning up after a crash.
        let saved = try? JSONFile<AppSettings>(Paths().settingsFile).load()
        paths = Paths(drivesFolder: saved?.drivesFolder)
        // Nothing may be mounted while folders move, including drives left by a crash.
        await stopStaleEngines()
        paths.migrate(from: Paths.legacy())
        settings = (try? JSONFile<AppSettings>(paths.settingsFile).load()) ?? AppSettings()
        paths = Paths(drivesFolder: settings.drivesFolder)
        do {
            try paths.createBaseDirectories()
        } catch {
            fatalError = "Couldn't create Kitty Finder's folders: \(error.localizedDescription)"
            return
        }
        guard let rclone = Rclone.locate() else {
            fatalError = RcloneError.binaryMissing.errorDescription
            return
        }
        self.rclone = rclone
        keepBundledClient()
        accounts = (try? JSONFile<[Account]>(paths.accountsFile).load()) ?? []
        do {
            try await prepareConfig(rclone)
        } catch {
            fatalError = error.localizedDescription
            return
        }
        for account in accounts {
            let controller = makeController(for: account)
            if account.enabled { startDrive(controller) }
        }
        if engineVersion.isEmpty, let result = try? await rclone.run(["version"], environment: rcloneEnvironment) {
            engineVersion = result.stdout.split(separator: "\n").first?.split(separator: " ").last.map(String.init) ?? ""
        }
        startObserving()
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3)) // let the network come back
                self?.mounts.values.forEach { $0.checkHealth() }
            }
        }
        network.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.networkChanged(offline: offline) }
        }
        network.start(queue: .global(qos: .utility))
        // Offline folders pick up changes made elsewhere every 15 minutes.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard let self else { return }
                self.syncAllOffline()
            }
        }
        updater.onAvailable = { [weak self] release in
            guard let self, self.settings.notifyUpdates else { return }
            Notifier.post(id: "update-\(release.version)", title: "Kitty Finder \(release.version) is available",
                          body: "Open Settings → Updates to install it.")
        }
        updater.prepareToInstall = { [weak self] in await self?.stopAll() }
        updater.installFailed = { [weak self] in await self?.restartAllDrives() }
        Task { [weak self] in
            while true {
                await self?.checkForUpdatesIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// Saves the Google client built into this copy of the app, so a later update
    /// installed from the public release (which has none) can still add drives.
    private func keepBundledClient() {
        guard !OAuthClient(id: settings.googleClientID, secret: settings.googleClientSecret).isComplete,
              let bundled = OAuthClient.bundled() else { return }
        settings.googleClientID = bundled.id
        settings.googleClientSecret = bundled.secret
        saveSettings()
    }

    /// Makes sure rclone.conf exists and is encrypted with a password kept in the keychain.
    private func prepareConfig(_ rclone: Rclone) async throws {
        let config = paths.rcloneConfig
        let fm = FileManager.default
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let encrypted = existing.contains("RCLONE_ENCRYPT_V0:")
        let account = Self.keychainAccount
        // Off the main thread: macOS may show an "allow access" prompt and block here.
        var lookup = await Task.detached { Keychain.lookup(account: account) }.value
        if lookup == .notFound {
            // Carry the password over from when the app was called KittyDock.
            let legacy = await Task.detached { Keychain.lookup(account: account, service: Keychain.legacyService) }.value
            if case .found(let password) = legacy {
                try await Task.detached { try Keychain.setPassword(password, account: account) }.value
                await Task.detached { Keychain.delete(account: account, service: Keychain.legacyService) }.value
            }
            if case .notFound = legacy {} else { lookup = legacy }
        }
        switch lookup {
        case .found(let password) where encrypted:
            configPassword = password
            return
        case .failed(let status):
            throw RcloneError.failed("Kitty Finder couldn't open its saved sign-ins (keychain error \(status)). "
                + "Click Try Again, and if macOS asks, enter your password and choose Always Allow.")
        case .found, .notFound:
            break
        }
        if encrypted {
            // Encrypted, but the keychain has no password for it: keep a copy and start over.
            let backup = config.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: config, to: backup)
            accounts = []
            saveAccounts()
        }
        let password = RemoteControl.randomPassword()
        try await Task.detached { try Keychain.setPassword(password, account: account) }.value
        if !fm.fileExists(atPath: config.path) {
            fm.createFile(atPath: config.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        var env = MountArguments.environment(configPassword: "")
        env.removeValue(forKey: "RCLONE_CONFIG_PASS")
        env["KITTYFINDER_NEW_PASS"] = password
        try await rclone.check(["config", "encryption", "set", "--config", config.path,
                                "--password-command", "/usr/bin/printenv KITTYFINDER_NEW_PASS"], environment: env)
        configPassword = password
    }

    /// Stops rclone processes left behind by a previous run that crashed (also from
    /// when the app was called KittyDock) and unmounts any drives they left behind.
    ///
    /// Drives are unmounted first, while their engines can still answer; each engine
    /// then notices and exits by itself. Engines that don't are signalled once (a
    /// second signal would kill one halfway through unmounting) and then killed.
    private func stopStaleEngines() async {
        let roots = [paths.mountRoot.path + "/", Paths.defaultDrivesFolder().path + "/", Paths.legacy().mountRoot.path + "/"]
        for mounted in MountTable.mountedPaths() where roots.contains(where: { mounted.hasPrefix($0) }) {
            await MountTable.forceUnmount(mounted)
        }
        let pattern = "nfsmount kd-[0-9a-z]+: .*--config .*/Application Support/(Kitty Finder|KittyDock)/rclone\\.conf"
        var engines = await Task.detached { Self.pids(matching: pattern) }.value
        engines = await ProcessWait.untilExited(engines, timeout: 1)
        for pid in engines { kill(pid, SIGTERM) }
        engines = await ProcessWait.untilExited(engines, timeout: 10)
        for pid in engines { kill(pid, SIGKILL) }
    }

    private nonisolated static func pids(matching pattern: String) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", pattern]
        let out = Pipe()
        pgrep.standardOutput = out
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    private var cacheLimitPerAccount: Int64 {
        MountArguments.perAccountCacheBytes(totalGB: settings.cacheLimitGB, accounts: accounts.filter(\.enabled).count)
    }

    private var rcloneEnvironment: [String: String] {
        MountArguments.environment(configPassword: configPassword)
    }

    // MARK: Drives

    private func makeController(for account: Account) -> MountController {
        let controller = MountController(account: account, paths: paths, rclone: rclone!)
        let id = account.id
        controller.onMounted = { [weak self] in self?.driveMounted(id) }
        controller.onProblem = { [weak self] message in self?.driveProblem(id, message) }
        mounts[id] = controller
        if offlineSyncs[id] == nil {
            let sync = OfflineSync(manifestFile: paths.offlineManifest(for: id))
            sync.onReady = { [weak self] folder in self?.offlineFolderReady(id, folder) }
            offlineSyncs[id] = sync
        }
        return controller
    }

    private func startDrive(_ controller: MountController) {
        controller.start(configPassword: configPassword, cacheLimitBytes: cacheLimitPerAccount, options: settings.mountOptions)
    }

    /// Stops a drive and starts it again with the current account details, folder and settings.
    private func restartDrive(_ id: String) async {
        guard rclone != nil, let account = accounts.first(where: { $0.id == id }) else { return }
        if let old = mounts[id] { await old.stop() }
        let controller = makeController(for: account)
        if account.enabled { startDrive(controller) }
    }

    private func restartAllDrives() async {
        for account in accounts { await restartDrive(account.id) }
    }

    private func driveMounted(_ id: String) {
        guard let controller = mounts[id] else { return }
        Task {
            await controller.setOffline(isOffline)
            await controller.applyOfflineFolders(account(id)?.offlineFolders ?? [])
            syncOffline(id)
        }
    }

    private func driveProblem(_ id: String, _ message: String) {
        guard settings.notifyUploadProblems, let account = account(id) else { return }
        // Restarts retry for a while; say each problem once an hour at most.
        if let last = lastProblem[id], last.message == message, Date().timeIntervalSince(last.date) < 3600 { return }
        lastProblem[id] = (message, Date())
        Notifier.post(id: "problem-\(id)", title: "\(account.title) needs attention", body: message)
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    func controller(for account: Account) -> MountController? { mounts[account.id] }

    var totalPendingUploads: Int { mounts.values.reduce(0) { $0 + $1.pendingUploads } }

    var hasProblem: Bool {
        fatalError != nil || mounts.values.contains { if case .failed = $0.state { return true } else { return false } }
    }

    var googleClient: OAuthClient? { OAuthClient.resolve(settings: settings) }

    func addGoogleAccount() {
        guard let rclone else { return }
        guard let client = googleClient else {
            signIn = .failed("Google sign-in isn't set up yet. Add your Google client in Settings → Google.")
            return
        }
        signInTask?.cancel()
        signIn = .waitingForBrowser(nil)
        signInTask = Task {
            do {
                let result = try await rclone.run(["authorize", "drive", client.id, client.secret],
                                                  environment: rcloneEnvironment) { output in
                    if let url = AuthorizeOutput.signInURL(in: output) {
                        Task { @MainActor [weak self] in
                            if case .waitingForBrowser(nil) = self?.signIn { self?.signIn = .waitingForBrowser(url) }
                        }
                    }
                }
                guard let token = AuthorizeOutput.token(in: result.combined),
                      let accessToken = AuthorizeOutput.accessToken(fromTokenJSON: token) else {
                    throw RcloneError.failed(Rclone.lastErrorLine(result.combined) ?? "Google sign-in didn't finish.")
                }
                signIn = .finishing
                let email = try await GoogleDriveAPI.email(accessToken: accessToken)
                guard !accounts.contains(where: { $0.provider == .googleDrive && $0.email == email }) else {
                    throw RcloneError.failed("\(email) is already in Kitty Finder.")
                }
                let account = Account(provider: .googleDrive, email: email)
                try await rclone.check(RemoteArguments.createDrive(name: account.remoteName, client: client, token: token,
                                                                   configPath: paths.rcloneConfig.path),
                                       environment: rcloneEnvironment)
                accounts.append(account)
                saveAccounts()
                startDrive(makeController(for: account))
                signIn = .idle
            } catch is CancellationError {
                signIn = .idle
            } catch {
                signIn = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = .idle
    }

    func setEnabled(_ enabled: Bool, for account: Account) async {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].enabled = enabled
        saveAccounts()
        await restartDrive(account.id)
    }

    /// Connects or disconnects every drive.
    func setAllEnabled(_ enabled: Bool) async {
        for account in accounts where account.enabled != enabled { await setEnabled(enabled, for: account) }
    }

    /// Gives a drive a custom name (empty restores the default). Returns why it
    /// couldn't, or nil once renamed. The drive remounts under its new name.
    func rename(_ account: Account, to name: String) async -> String? {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var renamed = accounts[index]
        renamed.displayName = trimmed.isEmpty || trimmed == renamed.defaultTitle ? nil : trimmed
        let oldFolder = accounts[index].mountPath(in: paths)
        let newFolder = renamed.mountPath(in: paths)
        if Account.folderName(renamed.title).isEmpty { return "Choose a name with at least one letter or number." }
        guard renamed.title != accounts[index].title else { return nil }
        let sameFolder = { (a: URL, b: URL) in a.path.lowercased() == b.path.lowercased() }
        if accounts.contains(where: { $0.id != account.id && sameFolder($0.mountPath(in: paths), newFolder) }) {
            return "Another drive already has this name."
        }
        if !sameFolder(oldFolder, newFolder) && !Self.isMissingOrEmpty(newFolder) {
            return "There's already a folder called “\(newFolder.lastPathComponent)” in the drives folder."
        }
        await mounts[account.id]?.stop()
        accounts[index] = renamed
        saveAccounts()
        Self.removeIfEmpty(oldFolder)
        await restartDrive(account.id)
        return nil
    }

    /// Removes the account from Kitty Finder. Returns false (and does nothing) if it
    /// has unuploaded changes and `force` is false.
    func remove(_ account: Account, force: Bool = false) async -> Bool {
        await mounts[account.id]?.stop()
        if !force && CacheInspector.hasUnuploadedChanges(cacheDir: paths.cacheDir(for: account.id)) {
            await restartDrive(account.id)
            return false
        }
        mounts[account.id] = nil
        offlineSyncs[account.id]?.cancel()
        offlineSyncs[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
        if let rclone {
            _ = try? await rclone.run(RemoteArguments.delete(name: account.remoteName, configPath: paths.rcloneConfig.path),
                                      environment: rcloneEnvironment)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: paths.cacheDir(for: account.id))
        try? fm.removeItem(at: paths.metaDir(for: account.id))
        try? fm.removeItem(at: paths.offlineManifest(for: account.id))
        Self.removeIfEmpty(account.mountPath(in: paths))
        return true
    }

    /// Deletes downloaded copies for an account. Returns false if it has
    /// changes that haven't uploaded yet (nothing is deleted then).
    func clearLocalCopies(_ account: Account) async -> Bool {
        guard let controller = mounts[account.id] else { return false }
        await controller.stop()
        let cacheDir = paths.cacheDir(for: account.id)
        let clean = !CacheInspector.hasUnuploadedChanges(cacheDir: cacheDir)
        if clean {
            try? FileManager.default.removeItem(at: cacheDir)
            // Offline folders download again once the drive is back.
            offlineSyncs[account.id]?.forget()
        }
        await restartDrive(account.id)
        return clean
    }

    func localCopyBytes(_ account: Account) -> Int64 {
        mounts[account.id]?.stats?.bytesUsed ?? CacheInspector.bytesUsed(cacheDir: paths.cacheDir(for: account.id))
    }

    func openInFinder(_ account: Account) {
        NSWorkspace.shared.open(account.mountPath(in: paths))
    }

    // MARK: Drives folder

    /// Moves every drive to `folder` (nil: the default, ~/Kitty Finder). Returns
    /// why it can't, or nil once moved.
    func moveDrivesFolder(to folder: URL?) async -> String? {
        let target = (folder ?? Paths.defaultDrivesFolder()).standardizedFileURL
        if let problem = paths.drivesFolderProblem(target) { return problem }
        let old = paths
        guard target.path != old.mountRoot.standardizedFileURL.path else { return nil }
        for account in accounts {
            let name = Account.folderName(account.title)
            if !Self.isMissingOrEmpty(target.appending(path: name)) {
                return "“\(target.lastPathComponent)” already has a folder called “\(name)”."
            }
        }
        for controller in mounts.values { await controller.stop() }
        for account in accounts { Self.removeIfEmpty(account.mountPath(in: old)) }
        Self.removeIfEmpty(old.mountRoot)
        settings.drivesFolder = target.path == Paths.defaultDrivesFolder().standardizedFileURL.path ? nil : target.path
        saveSettings()
        paths = Paths(drivesFolder: settings.drivesFolder)
        try? paths.createBaseDirectories()
        await restartAllDrives()
        return nil
    }

    private static func isMissingOrEmpty(_ folder: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: folder.path) else { return true }
        return !MountTable.isMounted(folder.path) && (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true
    }

    /// Removes a folder only if it is empty and nothing is mounted on it.
    private static func removeIfEmpty(_ folder: URL) {
        guard !MountTable.isMounted(folder.path) else { return }
        rmdir(folder.path) // fails, harmlessly, unless the folder is empty
    }

    // MARK: Offline folders

    private var driveRoots: [(id: String, root: URL)] { accounts.map { ($0.id, $0.mountPath(in: paths)) } }

    /// Keeps a folder (from Finder or Settings) downloaded. Returns a message if it can't.
    func keepOffline(_ url: URL) async -> String? {
        guard let (id, path) = OfflineFolders.locate(url, in: driveRoots),
              let index = accounts.firstIndex(where: { $0.id == id }) else {
            return "“\(url.lastPathComponent)” isn't on a Kitty Finder drive. Only folders in your drives can be kept offline."
        }
        guard let controller = mounts[id], controller.state == .mounted else {
            return "Connect \(accounts[index].title) first."
        }
        let before = accounts[index].offlineFolders
        let after = OfflineFolders.adding(path, to: before)
        guard after != before else { return nil }
        await controller.applyOfflineFolders(after)
        guard controller.supportsOffline else { return Self.offlineUnsupported }
        accounts[index].offlineFolders = after
        saveAccounts()
        syncOffline(id)
        return nil
    }

    /// Stops keeping a folder (or the kept folders inside it) offline. Returns a message if it can't.
    func stopKeepingOffline(_ url: URL) async -> String? {
        guard let (id, path) = OfflineFolders.locate(url, in: driveRoots) else {
            return "“\(url.lastPathComponent)” isn't on a Kitty Finder drive."
        }
        return await stopKeepingOffline(accountID: id, folder: path, name: url.lastPathComponent)
    }

    func stopKeepingOffline(accountID id: String, folder path: String, name: String? = nil) async -> String? {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return nil }
        let folders = accounts[index].offlineFolders
        let remaining = folders.filter { !OfflineFolders.contains(path, $0) }
        if remaining == folders {
            if let parent = folders.first(where: { OfflineFolders.contains($0, path) }) {
                return "“\(name ?? path)” is kept offline as part of “\(Self.displayName(parent, in: accounts[index]))”. Stop keeping that folder offline instead."
            }
            return "“\(name ?? path)” isn't kept offline."
        }
        accounts[index].offlineFolders = remaining
        saveAccounts()
        await mounts[id]?.applyOfflineFolders(remaining)
        syncOffline(id)
        return nil
    }

    static let offlineUnsupported = "This copy of Kitty Finder's sync engine can't keep folders offline. Install the latest version."

    static func displayName(_ folder: String, in account: Account) -> String {
        folder.isEmpty ? account.title : (folder as NSString).lastPathComponent
    }

    /// Downloads new and changed files in an account's offline folders.
    func syncOffline(_ id: String) {
        guard let account = account(id), let controller = mounts[id], let sync = offlineSyncs[id] else { return }
        let blocked: OfflineSync.Status?
        if !controller.supportsOffline {
            blocked = .failed(Self.offlineUnsupported)
        } else if controller.state != .mounted {
            blocked = .waiting(account.enabled ? "Waiting for the drive to connect" : "Drive disconnected")
        } else if isOffline {
            blocked = .waiting("Waiting for internet")
        } else {
            blocked = nil
        }
        sync.run(folders: account.offlineFolders, root: account.mountPath(in: paths), blocked: blocked,
                 keepFreeBytes: Int64(settings.keepFreeGB) * 1_073_741_824, cacheVolume: paths.appSupport)
    }

    func syncAllOffline() {
        for account in accounts { syncOffline(account.id) }
    }

    private func offlineFolderReady(_ id: String, _ folder: String) {
        guard settings.notifyOfflineReady, let account = account(id) else { return }
        let name = Self.displayName(folder, in: account)
        Notifier.post(id: "offline-\(id)-\(folder)", title: "“\(name)” is ready offline",
                      body: "You can open its files without an internet connection.")
    }

    private func networkChanged(offline: Bool) {
        guard offline != isOffline else { return }
        isOffline = offline
        for controller in mounts.values { Task { await controller.setOffline(offline) } }
        if !offline {
            Task {
                try? await Task.sleep(for: .seconds(3))
                mounts.values.forEach { $0.checkHealth() }
                syncAllOffline()
            }
        } else {
            syncAllOffline() // marks folders as waiting for the internet
        }
    }

    // MARK: Settings

    func update(_ change: (inout AppSettings) -> Void) async {
        let before = settings
        change(&settings)
        settings.drivesFolder = before.drivesFolder // changed only by moveDrivesFolder
        settings.clamp()
        guard settings != before else { return }
        saveSettings()
        if settings.cacheLimitGB != before.cacheLimitGB || settings.mountOptions != before.mountOptions {
            await restartAllDrives()
        }
        if settings.checkForUpdates && !before.checkForUpdates { await checkForUpdatesIfDue() }
    }

    private func saveSettings() {
        try? JSONFile<AppSettings>(paths.settingsFile).save(settings)
    }

    private func saveAccounts() {
        try? JSONFile<[Account]>(paths.accountsFile).save(accounts)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Kitty Finder: launch at login: \(error)")
            }
        }
    }

    func openLogs() { NSWorkspace.shared.open(paths.logs) }

    // MARK: Updates

    func checkForUpdates() async {
        await updater.check()
        settings.lastUpdateCheck = Date()
        saveSettings()
    }

    private func checkForUpdatesIfDue() async {
        guard settings.checkForUpdates else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        await checkForUpdates()
    }

    // MARK: Support

    var appVersion: String { UpdateChecker.currentVersion() }
    var buildNumber: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Versions and drive states for a bug report. Names, emails and file paths are left out.
    func diagnostics() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let names = accounts.flatMap { [$0.title, $0.email, $0.mountPath(in: paths).lastPathComponent] }
        var arch = utsname()
        uname(&arch)
        let machine = withUnsafePointer(to: &arch.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        var lines = [
            "Kitty Finder \(appVersion) (\(buildNumber))",
            "macOS \(macOSVersion) (\(machine))",
            "Engine \(engineVersion.isEmpty ? "unknown" : engineVersion)",
            "Network: \(isOffline ? "offline" : "online")",
            "Drives folder: \(settings.drivesFolder == nil ? "default" : "custom")",
            "Settings: keep \(settings.cacheLimitGB) GB, keep \(settings.keepFreeGB) GB free, \(settings.keepCopiesDays) days, "
                + "check every \(settings.pollSeconds) s, Google Docs \(settings.showGoogleDocs ? "on" : "off")",
            "Drives: \(accounts.count)",
        ]
        for (n, account) in accounts.enumerated() {
            let controller = mounts[account.id]
            let state: String
            switch controller?.state ?? .stopped {
            case .stopped: state = account.enabled ? "not connected" : "disconnected"
            case .starting: state = "connecting"
            case .mounted: state = "connected"
            case .paused: state = "ejected"
            case .failed(let message): state = "failed: " + Diagnostics.redact(message, home: home, names: names)
            }
            let stats = controller?.stats
            lines.append("- Drive \(n + 1) (\(account.provider.displayName)): \(state); "
                + "\(stats?.pendingUploads ?? 0) uploading, \(stats?.erroredFiles ?? 0) failed uploads, "
                + "\(ByteFormat.string(localCopyBytes(account))) on this Mac, \(account.offlineFolders.count) offline folders, "
                + "offline support \(controller?.supportsOffline == false ? "no" : "yes")")
        }
        return lines.joined(separator: "\n")
    }

    func reportProblem() {
        guard let url = Diagnostics.issueURL(repository: updater.repository ?? "redwan-cpp/Kitty-finder", appVersion: appVersion,
                                             macOS: macOSVersion, engine: engineVersion) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Removes every drive, sign-in and setting from this Mac and starts fresh.
    /// Nothing is deleted from the cloud. Returns false (and does nothing) if a
    /// drive has changes that haven't uploaded and `force` is false.
    func reset(force: Bool = false) async -> Bool {
        for controller in mounts.values { await controller.stop() }
        if !force, accounts.contains(where: { CacheInspector.hasUnuploadedChanges(cacheDir: paths.cacheDir(for: $0.id)) }) {
            await restartAllDrives()
            return false
        }
        cancelSignIn()
        offlineSyncs.values.forEach { $0.cancel() }
        let folders = accounts.map { $0.mountPath(in: paths) }
        mounts = [:]
        offlineSyncs = [:]
        accounts = []
        let fm = FileManager.default
        try? fm.removeItem(at: paths.appSupport)
        try? fm.removeItem(at: paths.logs)
        folders.forEach(Self.removeIfEmpty)
        Self.removeIfEmpty(paths.mountRoot)
        let account = Self.keychainAccount
        await Task.detached { Keychain.delete(account: account, service: Keychain.service) }.value
        settings = AppSettings()
        configPassword = ""
        await start()
        return true
    }

    // MARK: Quit

    func stopAll() async {
        offlineSyncs.values.forEach { $0.cancel() }
        for controller in mounts.values { await controller.stop() }
    }
}
