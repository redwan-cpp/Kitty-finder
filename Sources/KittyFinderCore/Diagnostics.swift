import Foundation

/// Text for bug reports, with personal details taken out.
public enum Diagnostics {
    /// Removes the home folder, email addresses, drive names and file paths from
    /// an error message, keeping what went wrong.
    public static func redact(_ text: String, home: String, names: [String]) -> String {
        var s = text
        // Longest first, so a name that contains another is replaced whole.
        for name in names.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            s = s.replacingOccurrences(of: name, with: "<drive>")
        }
        if !home.isEmpty { s = s.replacingOccurrences(of: home, with: "~") }
        s = s.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>",
                                   options: .regularExpression)
        // Anything below a drive is a file or folder name.
        s = s.replacingOccurrences(of: #"<drive>/[^"\n:]*"#, with: "<drive>/<path>", options: .regularExpression)
        // rclone log lines name the file first: "ERROR : Folder/file.txt: message"
        s = s.replacingOccurrences(of: #"(ERROR|NOTICE|INFO|CRITICAL|WARNING) ?: [^:\n]+:"#, with: "$1 : <file>:",
                                   options: .regularExpression)
        return s
    }

    /// A new GitHub issue with the versions filled in.
    public static func issueURL(repository: String, appVersion: String, macOS: String, engine: String) -> URL? {
        let body = """
        **What happened?**


        **What did you expect?**


        **Steps to reproduce**
        1.

        ---
        Kitty Finder \(appVersion) · macOS \(macOS) · engine \(engine)
        """
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [URLQueryItem(name: "body", value: body)]
        return components?.url
    }
}
