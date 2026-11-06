import Foundation

/// The Show me table: rows are power sources, columns lid open / lid closed.
/// Each cell says what the Mac does there now, in a few words.
public enum Table {
    public struct Cell: Equatable, Sendable {
        public var text: String
        /// The settings behind it, small, under the text.
        public var detail: String?
        /// Whether this is what macOS does out of the box.
        public var isDefault: Bool
    }

    /// macOS defaults on a MacBook: sleep 1, displaysleep 10 plugged in and
    /// 2 on battery, so it sleeps once the display is off.
    public static func defaultIdleMinutes(_ source: PowerSource) -> Int {
        source == .battery ? 2 : 10
    }

    public static func defaultOpenText(_ source: PowerSource) -> String {
        "sleeps after \(minutes(defaultIdleMinutes(source))) idle"
    }

    public static let defaultClosedText = "sleeps at once"

    public static func minutes(_ n: Int) -> String { "\(n) min" }

    /// Minutes of idle before the Mac sleeps with the lid open, nil for never.
    /// powerd holds "Prevent sleep while display is on", so the Mac only
    /// idle-sleeps once the display is off: max(sleep, displaysleep).
    public static func idleMinutes(_ s: SourceSettings) -> Int? {
        let sleep = s.sleep ?? 0
        let display = s.displaySleep ?? 0
        if sleep == 0 || display == 0 { return nil }
        return max(sleep, display)
    }

    /// `foreignDisableSleep`: `disablesleep 1` is set, and not by Nap.
    public static func openCell(_ source: PowerSource, settings: PowerSettings, rule: LidRule,
                                foreignDisableSleep: Bool) -> Cell {
        guard let s = settings.sources[source] else { return Cell(text: "unknown", detail: nil, isDefault: false) }
        let detail = "sleep \(s.sleep ?? 0), displaysleep \(s.displaySleep ?? 0)"
        if foreignDisableSleep {
            return Cell(text: "never sleeps (disablesleep 1)", detail: detail, isDefault: false)
        }
        guard let idle = idleMinutes(s) else {
            let display = s.displaySleep ?? 0
            let text = display == 0
                ? "never sleeps (display stays on)"
                : "never sleeps (display off after \(minutes(display)))"
            return Cell(text: text, detail: detail, isDefault: false)
        }
        if rule.staysAwake {
            // Nap holds disablesleep 1 on this source so the lid can close awake.
            return Cell(text: "never sleeps (held by the lid rule)", detail: detail, isDefault: false)
        }
        return Cell(text: "sleeps after \(minutes(idle)) idle", detail: detail,
                    isDefault: idle == defaultIdleMinutes(source))
    }

    public static func closedCell(_ source: PowerSource, rule: LidRule, batteryFloor: Int,
                                  foreignDisableSleep: Bool) -> Cell {
        if foreignDisableSleep {
            return Cell(text: "stays awake (disablesleep 1)", detail: nil, isDefault: false)
        }
        let early = source == .battery
            ? "sleeps early if hot or under \(batteryFloor)%"
            : "sleeps early if hot"
        switch rule {
        case .sleep:
            return Cell(text: defaultClosedText, detail: nil, isDefault: true)
        case .stayAwake(nil):
            return Cell(text: "stays awake", detail: early, isDefault: false)
        case .stayAwake(let m?):
            return Cell(text: "stays awake \(minutes(m)), then sleeps", detail: early, isDefault: false)
        }
    }

    /// The countdown bar, only while Nap keeps the Mac awake with the lid closed.
    public static func bar(_ guardian: LidGuard, timeZone: TimeZone = .current) -> [String]? {
        guard case .awake(let closedAt, let deadline) = guardian.phase else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        let then = deadline.map { "sleeps \(f.string(from: $0))" } ?? "stays awake (plugged in)"
        let early = guardian.onBattery
            ? "Sleeps early if hot or battery under \(guardian.batteryFloor)%."
            : "Sleeps early if hot."
        return ["Closed \(f.string(from: closedAt)) → \(then)", early]
    }

    /// What is keeping the Mac awake right now, in plain words. powerd's own
    /// assertions (display on, lid open) are left out: the table already says
    /// what they do. A known macOS service is named for what it is doing; any
    /// other process by its own name and the reason it gives.
    public static func awakeLines(_ assertions: Assertions) -> [String] {
        assertions.keepingAwake.filter { $0.process != "powerd" }.map { a in
            let left = a.timeoutSeconds.map { ", \(minutes(max(1, ($0 + 59) / 60))) left" } ?? ""
            var name = a.name
            if let m = name.firstMatch(of: /^osservice<([^(>]+)/) {
                name = String(m.1.split(separator: ".").last ?? m.1)
            }
            if let plain = plainWords(process: a.process, name: name) { return plain + left }
            if name.count > 30 { name = name.prefix(29) + "…" }
            let why = name.isEmpty || name == a.process ? "" : ", for \"\(name)\""
            return "\(a.process) (an app or service\(why))\(left)"
        }
    }

    /// macOS services seen holding the Mac awake, said as what they are doing.
    static func plainWords(process: String, name: String) -> String? {
        switch process {
        case "sharingd" where name.localizedCaseInsensitiveContains("handoff"):
            "Handoff: passing work between this Mac and a nearby iPhone or iPad"
        case "sharingd": "AirDrop or Handoff with a nearby device"
        case "caffeinate": "a caffeinate command, run from a terminal or by an app"
        case "runningboardd" where name == "dataaccessd": "Mail, Calendar and Contacts syncing"
        case "coreaudiod": "sound playing"
        case "backupd": "a Time Machine backup"
        case "mds", "mds_stores", "mdworker": "Spotlight indexing"
        case "softwareupdated": "a software update"
        case "bluetoothd": "a Bluetooth device"
        default: nil
        }
    }
}
