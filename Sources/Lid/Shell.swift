import Foundation
import LidCore

enum Shell {
    struct Result {
        var status: Int32
        var output: String
    }

    /// Runs a program and waits for it. Used for quick commands only
    /// (pmset -g ..., sudo -n pmset ...).
    static func run(_ path: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func pmset(_ arguments: String...) -> String {
        run("/usr/bin/pmset", arguments).output
    }

    /// Runs one of the commands allowed by Lid's sudoers file, never asking for
    /// a password: `sudo -n` fails instead.
    static func sudo(_ command: String) -> Result {
        run("/usr/bin/sudo", Sudoers.sudoArguments(command))
    }

    /// Runs a shell script as root through the standard macOS admin prompt.
    /// Returns nil on success, or the error to show. Lid never sees the password.
    @MainActor
    static func admin(_ shell: String, prompt: String) -> String? {
        let source = Sudoers.appleScript(shell: shell, prompt: prompt)
        guard let script = NSAppleScript(source: source) else { return "Could not build the admin script." }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
        return (error[NSAppleScript.errorMessage] as? String) ?? "Failed."
    }
}
