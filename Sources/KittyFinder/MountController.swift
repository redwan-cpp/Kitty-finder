import AppKit
import KittyFinderCore

enum MountState: Equatable {
    case stopped
    case starting
    case mounted
    case paused
    case failed(String)
}

/// Runs and supervises one account's `rclone nfsmount` process.
@Observable @MainActor
final class MountController {
    let account: Account
    private(set) var state: MountState = .stopped
    private(set) var stats: VFSStats?

    private let paths: Paths
    private let rclone: Rclone
    private var process: Process?
    private var remoteControl: RemoteControl?
    private var pollTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartAttempts = 0
    private var wantRunning = false
    private var configPassword = ""
    private var cacheLimitBytes: Int64 = 0
    private var options = MountOptions()

    /// Called each time the drive becomes available (after start, restart or wake).
    @ObservationIgnored var onMounted: (() -> Void)?
    /// Called when the drive stops working or a file fails to upload, with a message for people.
    @ObservationIgnored var onProblem: ((String) -> Void)?
    /// False once the engine has said it can't keep folders offline (an older engine).
    private(set) var supportsOffline = true
    /// Offline folders, pinned as the engine starts (it clears its cache at once,
    /// before they could be pinned over remote control).
    var offlineFolders: [String] = []

    /// For benchmarking: `defaults write app.kittyfinder.KittyFinder UseBaselineTuning -bool true`
    /// restores the original settings.
    static var tuning: MountTuning {
        UserDefaults.standard.bool(forKey: "UseBaselineTuning") ? .baseline : .tuned
    }

    init(account: Account, paths: Paths, rclone: Rclone) {
        self.account = account
        self.paths = paths
        self.rclone = rclone
    }

    var mountPath: URL { account.mountPath(in: paths) }
    var isRunning: Bool { process != nil }
    var pendingUploads: Int { stats?.pendingUploads ?? 0 }

    func start(configPassword: String, cacheLimitBytes: Int64, options: MountOptions) {
        self.configPassword = configPassword
        self.cacheLimitBytes = cacheLimitBytes
        self.options = options
        wantRunning = true
        restartAttempts = 0
        launch()
    }

    /// Stops the mount and waits for rclone to exit. Unfinished uploads stay in
    /// the cache and resume the next time the account is mounted.
    func stop() async {
        wantRunning = false
        restartTask?.cancel()
        guard let process else {
            await MountTable.forceUnmount(mountPath.path)
            state = .stopped
            return
        }
        // Unmount while the engine can still answer: it notices and exits by itself.
        // Signalling it first makes rclone run `diskutil unmount force`, which can hang
        // (for example with the drive open in Finder) and leave a dead mount if the
        // engine is then killed.
        await MountTable.forceUnmount(mountPath.path)
        // After a forced unmount the engine doesn't notice by itself; once signalled,
        // it finds nothing left to unmount and exits at once.
        let pid = process.processIdentifier
        if await !ProcessWait.untilExited([pid], timeout: 1).isEmpty {
            process.terminate()
            if await !ProcessWait.untilExited([pid], timeout: 5).isEmpty {
                kill(pid, SIGKILL)
            }
        }
        state = .stopped
    }

    /// Restarts the mount if it isn't healthy, for example after sleep.
    func checkHealth() {
        guard wantRunning else { return }
        if let process {
            if state == .mounted && !MountTable.isMounted(mountPath.path) {
                relaunchOnExit = true
                process.terminate()
            }
        } else {
            restartTask?.cancel()
            launch()
        }
    }

    private var relaunchOnExit = false
    private var clearingDeadMount = false

    private func launch() {
        guard wantRunning, process == nil, !clearingDeadMount else { return }
        let fm = FileManager.default
        let mountPath = self.mountPath.path

        // A previous rclone that died leaves a dead mount behind. Unmounting it can
        // block, so do it off the main thread and come back here when it's gone.
        if MountTable.isMounted(mountPath) {
            clearingDeadMount = true
            state = .starting
            Task { [weak self] in
                let cleared = await MountTable.forceUnmount(mountPath)
                guard let self else { return }
                self.clearingDeadMount = false
                if cleared {
                    self.launch()
                } else {
                    self.fail("macOS is still disconnecting this drive. If it says “Server connections interrupted”, click Disconnect.")
                    self.scheduleRestart()
                }
            }
            return
        }
        do {
            try fm.createDirectory(atPath: mountPath, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.cacheDir(for: account.id), withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.metaDir(for: account.id), withIntermediateDirectories: true)
        } catch {
            fail("Couldn't create Kitty Finder folders: \(error.localizedDescription)")
            return
        }
        guard let port = RemoteControl.freePort() else {
            fail("No free local port for Kitty Finder.")
            return
        }
        let rc = RemoteControl(port: port)
        let config = MountConfig(account: account, paths: paths, cacheLimitBytes: cacheLimitBytes, rcPort: port,
                                 pinnedFolders: offlineFolders)

        let process = Process()
        process.executableURL = rclone.binary
        // ExtraMountArguments (string array) adds rclone flags, for testing.
        let defaults = UserDefaults.standard
        process.arguments = MountArguments.nfsmount(config, tuning: Self.tuning, options: options,
                                                    extra: defaults.stringArray(forKey: "ExtraMountArguments") ?? [])
        process.environment = MountArguments.environment(configPassword: configPassword, rcUser: rc.user, rcPass: rc.password)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        fm.createFile(atPath: stderrLog.path, contents: nil)
        process.standardError = (try? FileHandle(forWritingTo: stderrLog)) ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let signaled = proc.terminationReason == .uncaughtSignal
            Task { @MainActor in self?.exited(status: status, signaled: signaled) }
        }
        do {
            try process.run()
        } catch {
            fail("Couldn't start the sync engine: \(error.localizedDescription)")
            return
        }
        self.process = process
        remoteControl = rc
        state = .starting
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            if MountTable.isMounted(mountPath.path) {
                if state == .starting {
                    state = .mounted
                    restartAttempts = 0
                    onMounted?()
                }
                if let rc = remoteControl, let fresh = try? await rc.vfsStats() {
                    if fresh.erroredFiles > (stats?.erroredFiles ?? 0) {
                        let n = fresh.erroredFiles
                        onProblem?("\(n) file\(n == 1 ? "" : "s") couldn't upload. Kitty Finder keeps trying.")
                    }
                    stats = fresh
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func exited(status: Int32, signaled: Bool) {
        process = nil
        remoteControl = nil
        pollTask?.cancel()
        stats = nil
        if MountTable.isMounted(mountPath.path) {
            let path = mountPath.path
            Task { await MountTable.forceUnmount(path) } // a relaunch waits for this itself
        }
        guard wantRunning else {
            state = .stopped
            return
        }
        if relaunchOnExit {
            relaunchOnExit = false
            launch()
            return
        }
        if status == 0 && !signaled {
            // A clean exit while we wanted it running means it was ejected in Finder
            wantRunning = false
            state = .paused
            return
        }
        fail(lastError() ?? "The sync engine stopped unexpectedly.")
        scheduleRestart()
    }

    // MARK: Offline folders

    /// Makes the engine keep exactly `folders` downloaded (drive-relative paths).
    func applyOfflineFolders(_ folders: [String]) async {
        offlineFolders = folders
        guard let rc = remoteControl, supportsOffline else { return }
        do {
            let current = Set(try await rc.pins())
            for folder in Set(folders).subtracting(current) { try await rc.pin(folder) }
            for folder in current.subtracting(folders) { try await rc.unpin(folder) }
        } catch RemoteControlError.unsupported {
            supportsOffline = false
        } catch {
            NSLog("Kitty Finder: offline folders: \(error.localizedDescription)")
        }
    }

    /// Where the engine keeps its record of each cached file, once it's running.
    func cacheMetaRoot() async -> URL? {
        if let path = stats?.metaPath { return URL(fileURLWithPath: path, isDirectory: true) }
        guard let path = try? await remoteControl?.vfsStats().metaPath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Tells the engine whether the Mac is offline.
    func setOffline(_ offline: Bool) async {
        guard let rc = remoteControl, supportsOffline else { return }
        do {
            try await rc.setOffline(offline)
        } catch RemoteControlError.unsupported {
            supportsOffline = false
        } catch {
            NSLog("Kitty Finder: offline mode: \(error.localizedDescription)")
        }
    }

    private func scheduleRestart() {
        restartAttempts += 1
        let delay = min(pow(2.0, Double(restartAttempts)), 60)
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        onProblem?(message)
    }

    private var stderrLog: URL { paths.logs.appending(path: "\(account.id).stderr.log") }

    private func lastError() -> String? {
        for url in [stderrLog, paths.logFile(for: account.id)] {
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            let tail = text.split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n")
            if tail.contains("ERROR") || tail.contains("CRITICAL") || url == stderrLog {
                if let line = Rclone.lastErrorLine(tail) { return line }
            }
        }
        return nil
    }
}
