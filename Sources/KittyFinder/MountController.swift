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

    init(account: Account, paths: Paths, rclone: Rclone) {
        self.account = account
        self.paths = paths
        self.rclone = rclone
    }

    var mountPath: URL { account.mountPath(in: paths) }
    var isRunning: Bool { process != nil }
    var pendingUploads: Int { stats?.pendingUploads ?? 0 }

    func start(configPassword: String, cacheLimitBytes: Int64) {
        self.configPassword = configPassword
        self.cacheLimitBytes = cacheLimitBytes
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
            state = .stopped
            return
        }
        process.terminate() // SIGTERM: rclone unmounts and exits
        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        if MountTable.isMounted(mountPath.path) {
            MountTable.forceUnmount(mountPath.path)
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

    private func launch() {
        guard wantRunning, process == nil else { return }
        let fm = FileManager.default
        let mountPath = self.mountPath.path

        // A previous rclone that died leaves a dead mount behind
        if MountTable.isMounted(mountPath) { MountTable.forceUnmount(mountPath) }
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
        let config = MountConfig(account: account, paths: paths, cacheLimitBytes: cacheLimitBytes, rcPort: port)

        let process = Process()
        process.executableURL = rclone.binary
        process.arguments = MountArguments.nfsmount(config)
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
                }
                if let rc = remoteControl, let fresh = try? await rc.vfsStats() {
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
        if MountTable.isMounted(mountPath.path) { MountTable.forceUnmount(mountPath.path) }
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
