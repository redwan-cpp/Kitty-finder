import AppKit
import KittyFinderCore

/// Checks GitHub for new releases and installs them in place.
///
/// Installing downloads the release's zip, checks it against the SHA-256 that
/// GitHub computed when it was uploaded, unpacks it, checks its signature,
/// bundle id and version, stops the drives, swaps the app and relaunches.
/// Any failure before the swap leaves the running app as it was.
@Observable @MainActor
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The newest release, once a check found one newer than this app.
    private(set) var available: Release?
    let currentVersion = UpdateChecker.currentVersion()
    let repository = UpdateChecker.repository()

    @ObservationIgnored var onAvailable: ((Release) -> Void)?
    /// Stops the drives before the app is replaced.
    @ObservationIgnored var prepareToInstall: (() async -> Void)?
    /// Starts the drives again if installing failed after they were stopped.
    @ObservationIgnored var installFailed: (() async -> Void)?

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func check() async {
        guard !isBusy else { return }
        guard let repository else {
            state = .failed("This copy of Kitty Finder doesn't know where to look for updates.")
            return
        }
        state = .checking
        do {
            let release = try await UpdateChecker.latest(repository: repository)
            if UpdateChecker.isNewer(release.version, than: currentVersion), release.installAsset != nil {
                let isNew = available?.version != release.version
                available = release
                state = .available
                if isNew { onAvailable?(release) }
            } else {
                available = nil
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install() async {
        guard !isBusy, let release = available, let asset = release.installAsset else { return }
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        var drivesStopped = false
        // A folder on the same disk as the app, so the swap is a rename.
        guard let work = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true) else {
            state = .failed("Couldn't make a folder for the download.")
            return
        }
        defer { try? fm.removeItem(at: work) }
        do {
            state = .downloading(0)
            let zip = work.appending(path: asset.name)
            try await download(asset.downloadURL, to: zip)
            guard try UpdateChecker.matches(zip, digest: asset.digest) else {
                throw RcloneError.failed("The download didn't match the checksum GitHub published, so it wasn't installed.")
            }
            state = .installing
            let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], failure: "Couldn't unpack the update.")
            guard let newApp = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
                  let bundle = Bundle(url: newApp) else {
                throw RcloneError.failed("The update doesn't contain the app.")
            }
            guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw RcloneError.failed("The update isn't Kitty Finder.")
            }
            let newVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard UpdateChecker.isNewer(newVersion, than: currentVersion) else {
                throw RcloneError.failed("The update (\(newVersion)) isn't newer than this copy.")
            }
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path],
                               failure: "The update's code signature is broken, so it wasn't installed.")
            guard fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                throw RcloneError.failed("Kitty Finder can't replace itself in “\(current.deletingLastPathComponent().path)”. "
                    + "Download the update from GitHub and drag it into Applications.")
            }
            await prepareToInstall?()
            drivesStopped = true
            _ = try fm.replaceItemAt(current, withItemAt: newApp)
            relaunch(current)
        } catch {
            state = .failed(error.localizedDescription)
            if drivesStopped { await installFailed?() }
        }
    }

    /// Opens the app again once this process has quit.
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? shell.run()
        RunLoop.main.perform { NSApp.terminate(nil) }
    }

    private func download(_ url: URL, to destination: URL) async throws {
        let box = TaskBox()
        let progress = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let fraction = box.fraction { self?.state = .downloading(fraction) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progress.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                if let error { return cont.resume(throwing: error) }
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return cont.resume(throwing: RcloneError.failed("The download failed (GitHub said \((response as? HTTPURLResponse)?.statusCode ?? 0))."))
                }
                // The downloaded file is deleted when this handler returns.
                do {
                    try FileManager.default.moveItem(at: file, to: destination)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            box.set(task)
            task.resume()
        }
    }

    private static func run(_ tool: String, _ arguments: [String], failure: String) async throws {
        let status: Int32 = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
        guard status == 0 else { throw RcloneError.failed(failure) }
    }
}

/// Holds the running download task, so its progress can be read from elsewhere.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?

    func set(_ task: URLSessionDownloadTask) { lock.withLock { self.task = task } }

    var fraction: Double? { lock.withLock { task.map { $0.progress.fractionCompleted } } }
}
