import Foundation

/// Subset of rclone's `vfs/stats` response.
public struct VFSStats: Decodable, Equatable, Sendable {
    public var bytesUsed: Int64 = 0
    public var files: Int = 0
    public var erroredFiles: Int = 0
    public var outOfSpace: Bool = false
    public var uploadsInProgress: Int = 0
    public var uploadsQueued: Int = 0

    public var pendingUploads: Int { uploadsInProgress + uploadsQueued }

    public init() {}

    enum CodingKeys: String, CodingKey { case diskCache }
    enum DiskKeys: String, CodingKey {
        case bytesUsed, files, erroredFiles, outOfSpace, uploadsInProgress, uploadsQueued
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        guard root.contains(.diskCache) else { return }
        let d = try root.nestedContainer(keyedBy: DiskKeys.self, forKey: .diskCache)
        bytesUsed = try d.decodeIfPresent(Int64.self, forKey: .bytesUsed) ?? 0
        files = try d.decodeIfPresent(Int.self, forKey: .files) ?? 0
        erroredFiles = try d.decodeIfPresent(Int.self, forKey: .erroredFiles) ?? 0
        outOfSpace = try d.decodeIfPresent(Bool.self, forKey: .outOfSpace) ?? false
        uploadsInProgress = try d.decodeIfPresent(Int.self, forKey: .uploadsInProgress) ?? 0
        uploadsQueued = try d.decodeIfPresent(Int.self, forKey: .uploadsQueued) ?? 0
    }
}

/// Talks to one rclone process's remote-control API on localhost.
public struct RemoteControl: Sendable {
    public let port: Int
    public let user: String
    public let password: String

    public init(port: Int, user: String = "kittyfinder", password: String = RemoteControl.randomPassword()) {
        self.port = port
        self.user = user
        self.password = password
    }

    public func vfsStats() async throws -> VFSStats {
        try JSONDecoder().decode(VFSStats.self, from: await call("vfs/stats"))
    }

    public func call(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 3) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(method)")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 404 { throw RemoteControlError.unsupported(method) }
            throw RcloneError.failed("rclone remote control returned \(status)")
        }
        return data
    }

    /// Folders kept offline (needs the pinning patch in the engine).
    public func pins() async throws -> [String] {
        struct Pins: Decodable { let pins: [String]? }
        return try JSONDecoder().decode(Pins.self, from: await call("vfs/pin")).pins ?? []
    }

    public func pin(_ folder: String) async throws { _ = try await call("vfs/pin", params: ["add": folder]) }
    public func unpin(_ folder: String) async throws { _ = try await call("vfs/pin", params: ["remove": folder]) }

    /// Tells the engine whether the Mac is offline, so it serves only downloaded files without waiting on the network.
    public func setOffline(_ offline: Bool) async throws {
        _ = try await call("vfs/offline", params: ["offline": offline])
    }

    public static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// A free TCP port on localhost.
    public static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }
}

public enum RemoteControlError: LocalizedError, Equatable {
    /// The engine doesn't have this command (an older engine).
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let method): return "This version of the sync engine doesn't support \(method)."
        }
    }
}
