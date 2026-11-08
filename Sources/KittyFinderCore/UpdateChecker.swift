import CryptoKit
import Foundation

/// A GitHub release, as returned by the releases API.
public struct Release: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let size: Int64
        public let downloadURL: URL
        /// "sha256:<hex>", computed by GitHub when the file was uploaded.
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case downloadURL = "browser_download_url"
        }
    }

    public let tag: String
    public let name: String?
    public let notes: String?
    public let pageURL: URL
    public let assets: [Asset]
    public let draft: Bool
    public let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case name, assets, draft, prerelease
        case tag = "tag_name"
        case notes = "body"
        case pageURL = "html_url"
    }

    /// Version number without a leading "v".
    public var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    /// The zip people install: the public build (no Google client inside).
    public var installAsset: Asset? {
        assets.first { $0.name.hasSuffix("-public.zip") } ?? assets.first { $0.name.hasSuffix(".zip") }
    }
}

public enum UpdateChecker {
    /// The GitHub repository updates come from, e.g. "redwan-cpp/Kitty-finder"
    /// (Info.plist key KFUpdateRepository).
    public static func repository(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "KFUpdateRepository") as? String
    }

    public static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The latest published (not draft, not pre-release) release.
    public static func latest(repository: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KittyFinder-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RcloneError.failed("Couldn't check for updates (GitHub said \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// True if version `a` is newer than `b` ("0.10.0" > "0.9.1"; a leading "v" is ignored).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let trimmed = v.hasPrefix("v") ? String(v.dropFirst()) : v
            return trimmed.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Lower-case hex SHA-256 of a file, read in chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True if `file` matches GitHub's "sha256:<hex>" digest.
    public static func matches(_ file: URL, digest: String?) throws -> Bool {
        guard let digest, digest.hasPrefix("sha256:") else { return false }
        return try sha256(of: file) == digest.dropFirst("sha256:".count).lowercased()
    }
}
