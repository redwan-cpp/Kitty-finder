import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var combined: String { stdout + stderr }
}

public enum RcloneError: LocalizedError, Equatable {
    case binaryMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing: return "The bundled rclone engine is missing. Reinstall Kitty Finder."
        case .failed(let message): return message
        }
    }
}

/// Runs the bundled rclone binary.
public struct Rclone: Sendable {
    public let binary: URL

    public init(binary: URL) { self.binary = binary }

    /// The binary inside the app bundle, or `$KITTYFINDER_RCLONE` during development.
    public static func locate(bundle: Bundle = .main) -> Rclone? {
        if let override = ProcessInfo.processInfo.environment["KITTYFINDER_RCLONE"] {
            return Rclone(binary: URL(fileURLWithPath: override))
        }
        guard let url = bundle.url(forResource: "rclone", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return Rclone(binary: url)
    }

    /// Runs rclone to completion. Cancelling the task terminates the process.
    /// `onOutput` receives everything printed so far (stdout and stderr), as it arrives.
    public func run(_ arguments: [String], environment: [String: String],
                    onOutput: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drain both pipes while the process runs so a chatty process can't block.
        let transcript = Transcript(onOutput)
        async let outData = Self.readAll(out.fileHandleForReading, transcript)
        async let errData = Self.readAll(err.fileHandleForReading, transcript)

        let box = ProcessBox(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    try? out.fileHandleForWriting.close()
                    try? err.fileHandleForWriting.close()
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }
        let stdout = String(decoding: await outData, as: UTF8.self)
        let stderr = String(decoding: await errData, as: UTF8.self)
        try Task.checkCancellation()
        return ProcessResult(status: status, stdout: stdout, stderr: stderr)
    }

    /// Runs rclone and throws with its error output if it fails.
    @discardableResult
    public func check(_ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        let result = try await run(arguments, environment: environment)
        guard result.status == 0 else {
            throw RcloneError.failed(Self.lastErrorLine(result.combined) ?? "rclone exited with status \(result.status)")
        }
        return result
    }

    /// The most useful line of rclone output to show a person.
    public static func lastErrorLine(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let interesting = lines.last { $0.contains("ERROR") || $0.contains("CRITICAL") || $0.contains("Failed") } ?? lines.last
        return interesting.map { line in
            // Drop rclone's "2026/11/06 10:00:00 ERROR : " prefix
            if let range = line.range(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} [A-Z]+ *: *"#, options: .regularExpression) {
                return String(line[range.upperBound...])
            }
            return line
        }
    }

    private static func readAll(_ handle: FileHandle, _ transcript: Transcript) async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var all = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    all.append(chunk)
                    transcript.append(chunk)
                }
                cont.resume(returning: all)
            }
        }
    }
}

/// Collects output from both pipes and reports the running text.
final class Transcript: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private let onOutput: (@Sendable (String) -> Void)?

    init(_ onOutput: (@Sendable (String) -> Void)?) { self.onOutput = onOutput }

    func append(_ data: Data) {
        guard let onOutput else { return }
        lock.lock()
        text += String(decoding: data, as: UTF8.self)
        let snapshot = text
        lock.unlock()
        onOutput(snapshot)
    }
}

/// Lets a cancellation handler terminate a process from another thread.
final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}
