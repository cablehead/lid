import Foundation

/// Turns settings into short plain sentences.
public enum Explain {
    public static func minutes(_ n: Int) -> String {
        n == 1 ? "1 minute" : "\(n) minutes"
    }

    /// What idle does on one power source, with the lid open.
    /// macOS holds "Prevent sleep while display is on" (powerd), so the Mac
    /// only idle-sleeps after the display has turned off.
    public static func idle(_ s: SourceSettings) -> String {
        let sleep = s.sleep ?? 0
        let display = s.displaySleep ?? 0
        switch (sleep, display) {
        case (0, 0):
            return "never sleeps when idle, and the display never turns off."
        case (0, _):
            return "the display turns off after \(minutes(display)) idle. The Mac never sleeps when idle."
        case (_, 0):
            return "the Mac sleeps after \(minutes(sleep)) idle, but never while the display is on "
                + "(the display never turns off), so in practice it never idle-sleeps with the lid open."
        default:
            let then = sleep <= display ? "right after" : "after \(minutes(sleep)) idle"
            return "the display turns off after \(minutes(display)) idle, and the Mac sleeps \(then)."
        }
    }

    /// The plain sentences for the current settings: one per power source
    /// (merged when they say the same thing), then the lid.
    public static func sentences(_ settings: PowerSettings) -> [String] {
        if settings.sleepDisabled {
            return ["Sleep is turned off (disablesleep 1): the Mac never sleeps, not even with the lid closed."]
        }
        var lines: [String] = []
        let present = PowerSource.allCases.filter { settings.sources[$0] != nil }
        let texts = present.map { idle(settings.sources[$0]!) }
        if present.count > 1, Set(texts).count == 1 {
            let names = present.map(\.label)
            lines.append(names.joined(separator: " and ") + ": " + texts[0])
        } else {
            for (source, text) in zip(present, texts) {
                lines.append(source.label + ": " + text)
            }
        }
        lines.append("Lid closed: sleeps at once (unless an external display is connected).")
        return lines
    }

    /// One short line per process keeping the Mac awake right now.
    public static func awake(_ assertions: Assertions) -> [String] {
        // The display line first: it is the one that explains idle sleep.
        let isDisplay = { (a: Assertion) in
            a.process == "powerd" && a.name.localizedCaseInsensitiveContains("display is on")
        }
        let all = assertions.keepingAwake
        return (all.filter(isDisplay) + all.filter { !isDisplay($0) }).map { a in
            if isDisplay(a) {
                return "The display is on (macOS never idle-sleeps while it is)."
            }
            if a.process == "powerd", a.name.localizedCaseInsensitiveContains("lid") {
                return "The lid is open."
            }
            var name = a.name
            if let m = name.firstMatch(of: /^osservice<([^(>]+)/) {
                name = "for \(m.1)"
            } else if name.count > 60 {
                name = name.prefix(57) + "..."
            }
            var line = "\(a.process) (pid \(a.pid)): \(name)"
            if let secs = a.timeoutSeconds { line += ", for \(secs) s more" }
            return line
        }
    }
}
