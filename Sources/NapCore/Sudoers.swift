import Foundation

/// The one-time permission: a sudoers drop-in that lets the user run exactly
/// three `pmset` commands as root without a password, so the lid timer never
/// needs a password prompt.
public enum Sudoers {
    public static let path = "/private/etc/sudoers.d/nap"

    /// The only commands the file allows, exactly as Nap runs them.
    public static let commands = [
        "/usr/bin/pmset -a disablesleep 0",
        "/usr/bin/pmset -a disablesleep 1",
        "/usr/bin/pmset sleepnow",
    ]

    public enum Failure: Error, Equatable {
        case unsafeUserName(String)
    }

    /// A user name that needs no escaping in sudoers.
    public static func isSafe(userName: String) -> Bool {
        guard userName != "ALL", let first = userName.first, first.isLetter || first == "_" else { return false }
        return userName.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    /// The exact file contents.
    public static func contents(userName: String) throws -> String {
        guard isSafe(userName: userName) else { throw Failure.unsafeUserName(userName) }
        return """
        # Written by Nap. Lets \(userName) run only these commands as root, without a password.
        \(userName) ALL = (root) NOPASSWD: \(commands.joined(separator: ", "))

        """
    }

    /// The shell script run as root (through the admin prompt) to install the
    /// file: write it to a temporary name in the same folder (sudo ignores
    /// names with a dot), check it with `visudo -cf`, then move it into place.
    public static func installScript(userName: String) throws -> String {
        let body = Data(try contents(userName: userName).utf8).base64EncodedString()
        return [
            "set -e",
            "/bin/mkdir -p /private/etc/sudoers.d",
            "tmp=$(/usr/bin/mktemp /private/etc/sudoers.d/nap.XXXXXX)",
            "trap '/bin/rm -f \"$tmp\"' EXIT",
            "echo \(body) | /usr/bin/base64 -D > \"$tmp\"",
            "/usr/sbin/chown root:wheel \"$tmp\"",
            "/bin/chmod 0440 \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\"",
            "/bin/mv -f \"$tmp\" \(path)",
        ].joined(separator: "\n")
    }

    /// The shell script run as root to remove it. Sleep is turned back on
    /// first, so removing never leaves it off.
    public static let removeScript = [
        "/usr/bin/pmset -a disablesleep 0",
        "/bin/rm -f \(path)",
    ].joined(separator: "\n")

    /// Arguments to `/usr/bin/sudo` that run one allowed command without ever
    /// asking for a password (`-n`: fail instead).
    public static func sudoArguments(_ command: String) -> [String] {
        ["-n"] + command.split(separator: " ").map(String.init)
    }

    /// AppleScript that runs a shell script with administrator privileges,
    /// through the standard macOS admin prompt.
    public static func appleScript(shell: String, prompt: String) -> String {
        "do shell script \(quote(shell)) with prompt \(quote(prompt)) with administrator privileges"
    }

    /// An AppleScript string literal.
    public static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
