import Foundation

/// A Google OAuth "Desktop app" client.
public struct OAuthClient: Equatable, Sendable {
    public var id: String
    public var secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }

    public var isComplete: Bool {
        !id.trimmingCharacters(in: .whitespaces).isEmpty && !secret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The client entered in Settings first, then the one bundled with the app
    /// (GoogleOAuth.plist). rclone's shared client is being retired, so there is
    /// no fallback beyond these.
    public static func resolve(settings: AppSettings, bundle: Bundle = .main) -> OAuthClient? {
        let fromSettings = OAuthClient(id: settings.googleClientID, secret: settings.googleClientSecret)
        if fromSettings.isComplete { return fromSettings }
        guard let url = bundle.url(forResource: "GoogleOAuth", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String],
              let id = dict["ClientID"], let secret = dict["ClientSecret"] else { return nil }
        let bundled = OAuthClient(id: id, secret: secret)
        return bundled.isComplete ? bundled : nil
    }
}

/// Parsing for `rclone authorize` output and the token it produces.
public enum AuthorizeOutput {
    /// rclone prints the token between "--->" and "<---End paste".
    public static func token(in output: String) -> String? {
        guard let start = output.range(of: "--->"),
              let end = output.range(of: "<---End paste", range: start.upperBound..<output.endIndex) else { return nil }
        let token = output[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The local sign-in link rclone serves, for when the browser doesn't open.
    public static func signInURL(in output: String) -> URL? {
        guard let range = output.range(of: #"http://127\.0\.0\.1:\d+/auth\?state=[A-Za-z0-9_\-]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(output[range]))
    }

    public static func accessToken(fromTokenJSON json: String) -> String? {
        struct Token: Decodable { let access_token: String }
        return (try? JSONDecoder().decode(Token.self, from: Data(json.utf8)))?.access_token
    }
}

public enum GoogleDriveAPI {
    /// The signed-in account's email address.
    public static func email(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        struct About: Decodable { struct User: Decodable { let emailAddress: String }; let user: User }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let about = try? JSONDecoder().decode(About.self, from: data) else {
            throw RcloneError.failed("Couldn't read your Google account details.")
        }
        return about.user.emailAddress
    }
}

public enum RemoteArguments {
    /// `rclone config create` for a Google Drive remote from an authorized token.
    public static func createDrive(name: String, client: OAuthClient, token: String, configPath: String) -> [String] {
        [
            "config", "create", name, "drive",
            "client_id=\(client.id)",
            "client_secret=\(client.secret)",
            "scope=drive",
            "export_formats=webloc",
            "token=\(token)",
            "config_refresh_token=false",
            "config_change_team_drive=false",
            "--non-interactive",
            "--config", configPath,
        ]
    }

    public static func delete(name: String, configPath: String) -> [String] {
        ["config", "delete", name, "--config", configPath]
    }
}
