import AppKit
import KittyFinderCore
import ServiceManagement

enum SignInState: Equatable {
    case idle
    case waitingForBrowser(URL?)
    case finishing
    case failed(String)
}

/// App-wide state: accounts, settings, mounts and sign-in.
@Observable @MainActor
final class AppModel {
    let paths = Paths()
    private(set) var accounts: [Account] = []
    private(set) var settings = AppSettings()
    private(set) var mounts: [String: MountController] = [:]
    var signIn: SignInState = .idle
    private(set) var fatalError: String?
    /// True until startup finishes, including any keychain prompt macOS shows.
    private(set) var isStarting = true
    /// Opens the Settings window; set by the app delegate.
    @ObservationIgnored var openSettingsHandler: (() -> Void)?

    private var rclone: Rclone?
    private var configPassword = ""
    private var signInTask: Task<Void, Never>?
    private var observingWake = false
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
        // Nothing may be mounted while folders move, including drives left by a crash.
        await stopStaleEngines()
        paths.migrate(from: Paths.legacy())
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
        settings = (try? JSONFile<AppSettings>(paths.settingsFile).load()) ?? AppSettings()
        accounts = (try? JSONFile<[Account]>(paths.accountsFile).load()) ?? []
        do {
            try await prepareConfig(rclone)
        } catch {
            fatalError = error.localizedDescription
            return
        }
        for account in accounts {
            let controller = MountController(account: account, paths: paths, rclone: rclone)
            mounts[account.id] = controller
            if account.enabled { controller.start(configPassword: configPassword, cacheLimitBytes: cacheLimitPerAccount) }
        }
        guard !observingWake else { return }
        observingWake = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3)) // let the network come back
                self?.mounts.values.forEach { $0.checkHealth() }
            }
        }
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
            try? JSONFile<[Account]>(paths.accountsFile).save(accounts)
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
    private func stopStaleEngines() async {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-f", "nfsmount kd-[0-9a-z]+: .*--config .*/Application Support/(Kitty Finder|KittyDock)/rclone\\.conf"]
        try? pkill.run()
        pkill.waitUntilExit()
        if pkill.terminationStatus == 0 { try? await Task.sleep(for: .seconds(2)) }
        let roots = [paths.mountRoot.path + "/", Paths.legacy().mountRoot.path + "/"]
        for mounted in MountTable.mountedPaths() where roots.contains(where: { mounted.hasPrefix($0) }) {
            MountTable.forceUnmount(mounted)
        }
    }

    private var cacheLimitPerAccount: Int64 {
        MountArguments.perAccountCacheBytes(totalGB: settings.cacheLimitGB, accounts: accounts.filter(\.enabled).count)
    }

    private var rcloneEnvironment: [String: String] {
        MountArguments.environment(configPassword: configPassword)
    }

    // MARK: Accounts

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
                try JSONFile<[Account]>(paths.accountsFile).save(accounts)
                let controller = MountController(account: account, paths: paths, rclone: rclone)
                mounts[account.id] = controller
                controller.start(configPassword: configPassword, cacheLimitBytes: cacheLimitPerAccount)
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
        guard let index = accounts.firstIndex(of: account) else { return }
        accounts[index].enabled = enabled
        try? JSONFile<[Account]>(paths.accountsFile).save(accounts)
        let updated = accounts[index]
        if let old = mounts[account.id] { await old.stop() }
        guard let rclone else { return }
        let controller = MountController(account: updated, paths: paths, rclone: rclone)
        mounts[account.id] = controller
        if enabled { controller.start(configPassword: configPassword, cacheLimitBytes: cacheLimitPerAccount) }
    }

    /// Removes the account from Kitty Finder. Returns false (and does nothing) if it
    /// has unuploaded changes and `force` is false.
    func remove(_ account: Account, force: Bool = false) async -> Bool {
        await mounts[account.id]?.stop()
        if !force && CacheInspector.hasUnuploadedChanges(cacheDir: paths.cacheDir(for: account.id)) {
            mounts[account.id]?.start(configPassword: configPassword, cacheLimitBytes: cacheLimitPerAccount)
            return false
        }
        mounts[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        try? JSONFile<[Account]>(paths.accountsFile).save(accounts)
        if let rclone {
            _ = try? await rclone.run(RemoteArguments.delete(name: account.remoteName, configPath: paths.rcloneConfig.path),
                                      environment: rcloneEnvironment)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: paths.cacheDir(for: account.id))
        try? fm.removeItem(at: paths.metaDir(for: account.id))
        let mountPath = account.mountPath(in: paths)
        if !MountTable.isMounted(mountPath.path), (try? fm.contentsOfDirectory(atPath: mountPath.path))?.isEmpty == true {
            try? fm.removeItem(at: mountPath)
        }
        return true
    }

    /// Deletes downloaded copies for an account. Returns false if it has
    /// changes that haven't uploaded yet (nothing is deleted then).
    func clearLocalCopies(_ account: Account) async -> Bool {
        guard let controller = mounts[account.id] else { return false }
        let wasRunning = controller.isRunning
        await controller.stop()
        let cacheDir = paths.cacheDir(for: account.id)
        let clean = !CacheInspector.hasUnuploadedChanges(cacheDir: cacheDir)
        if clean { try? FileManager.default.removeItem(at: cacheDir) }
        if wasRunning { controller.start(configPassword: configPassword, cacheLimitBytes: cacheLimitPerAccount) }
        return clean
    }

    func localCopyBytes(_ account: Account) -> Int64 {
        mounts[account.id]?.stats?.bytesUsed ?? CacheInspector.bytesUsed(cacheDir: paths.cacheDir(for: account.id))
    }

    func openInFinder(_ account: Account) {
        NSWorkspace.shared.open(account.mountPath(in: paths))
    }

    // MARK: Settings

    func update(_ change: (inout AppSettings) -> Void) async {
        let before = settings
        change(&settings)
        settings.cacheLimitGB = min(max(settings.cacheLimitGB, AppSettings.cacheLimitRange.lowerBound), AppSettings.cacheLimitRange.upperBound)
        try? JSONFile<AppSettings>(paths.settingsFile).save(settings)
        if settings.cacheLimitGB != before.cacheLimitGB { await applyCacheLimit() }
    }

    /// Restarts enabled mounts so they pick up a changed cache limit.
    private func applyCacheLimit() async {
        for account in accounts {
            guard let controller = mounts[account.id] else { continue }
            await controller.stop()
            if account.enabled { controller.start(configPassword: configPassword, cacheLimitBytes: cacheLimitPerAccount) }
        }
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

    // MARK: Quit

    func stopAll() async {
        for controller in mounts.values { await controller.stop() }
    }
}
