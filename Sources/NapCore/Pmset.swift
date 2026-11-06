import Foundation

/// A power source as `pmset` names it.
public enum PowerSource: String, CaseIterable, Sendable {
    case ac = "AC Power"
    case battery = "Battery Power"
    case ups = "UPS Power"

    /// The plain name used in sentences.
    public var label: String {
        switch self {
        case .ac: "Plugged in"
        case .battery: "On battery"
        case .ups: "On UPS"
        }
    }

    /// The `pmset` flag that targets this source.
    public var flag: String {
        switch self {
        case .ac: "-c"
        case .battery: "-b"
        case .ups: "-u"
        }
    }
}

/// The settings of one power source, from `pmset -g custom`.
public struct SourceSettings: Equatable, Sendable {
    public var values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public func int(_ key: String) -> Int? {
        values[key].flatMap { Int($0) }
    }

    /// Minutes of idle before system sleep; 0 means never.
    public var sleep: Int? { int("sleep") }
    /// Minutes of idle before the display turns off; 0 means never.
    public var displaySleep: Int? { int("displaysleep") }
}

/// What `pmset -g custom` reports, per power source.
public struct PowerSettings: Equatable, Sendable {
    public var sources: [PowerSource: SourceSettings]
    /// `SleepDisabled` from `pmset -g` (set by `pmset -a disablesleep 1`).
    public var sleepDisabled: Bool

    public init(sources: [PowerSource: SourceSettings], sleepDisabled: Bool = false) {
        self.sources = sources
        self.sleepDisabled = sleepDisabled
    }

    /// Parses `pmset -g custom`. Lines are " key   value"; a key may contain
    /// spaces ("Sleep On Power Button 1"), so the value is the last token.
    public static func parse(custom text: String, systemWide: String? = nil) -> PowerSettings {
        var sources: [PowerSource: SourceSettings] = [:]
        var current: PowerSource?
        var values: [String: String] = [:]
        func flush() {
            if let current { sources[current] = SourceSettings(values) }
            values = [:]
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if !line.hasPrefix(" "), line.hasSuffix(":") {
                flush()
                current = PowerSource(rawValue: String(line.dropLast()))
                continue
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 2 else { continue }
            let key = tokens.dropLast().joined(separator: " ")
            values[key] = String(tokens.last!)
        }
        flush()
        return PowerSettings(
            sources: sources,
            sleepDisabled: systemWide.map(parseSleepDisabled) ?? false
        )
    }

    /// Reads `SleepDisabled` from `pmset -g` output.
    public static func parseSleepDisabled(_ text: String) -> Bool {
        for raw in text.split(separator: "\n") {
            let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if tokens.first == "SleepDisabled", tokens.count >= 2 {
                return tokens[1] == "1"
            }
        }
        return false
    }
}

/// One process holding a power assertion, from `pmset -g assertions`.
public struct Assertion: Equatable, Sendable {
    public var pid: Int
    public var process: String
    public var type: String
    public var name: String
    /// Seconds until the assertion times out, when it has a timeout.
    public var timeoutSeconds: Int?
}

public struct Assertions: Equatable, Sendable {
    /// "Assertion status system-wide" counts, by type.
    public var systemWide: [String: Int]
    public var byProcess: [Assertion]

    public init(systemWide: [String: Int] = [:], byProcess: [Assertion] = []) {
        self.systemWide = systemWide
        self.byProcess = byProcess
    }

    /// Types that keep the system (not only the display) awake.
    public static let keepAwakeTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep",
        "NoIdleSleepAssertion", "DenySystemSleep",
    ]

    /// The assertions that keep the Mac from sleeping.
    public var keepingAwake: [Assertion] {
        byProcess.filter { Self.keepAwakeTypes.contains($0.type) }
    }

    public static func parse(_ text: String) -> Assertions {
        var systemWide: [String: Int] = [:]
        var byProcess: [Assertion] = []
        enum Section { case none, systemWide, byProcess, kernel }
        var section = Section.none
        let pattern = /pid (\d+)\((.+?)\): \[0x[0-9a-fA-F]+\] [\d:]+ (\w+) named: "(.*)"/
        let timeout = /Timeout will fire in (\d+) secs/
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("Assertion status system-wide") { section = .systemWide; continue }
            if line.hasPrefix("Listed by owning process") { section = .byProcess; continue }
            if line.hasPrefix("Kernel Assertions") { section = .kernel; continue }
            switch section {
            case .systemWide:
                let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if tokens.count == 2, let n = Int(tokens[1]) { systemWide[String(tokens[0])] = n }
            case .byProcess:
                if let m = line.firstMatch(of: pattern), let pid = Int(m.1) {
                    byProcess.append(Assertion(pid: pid, process: String(m.2), type: String(m.3), name: String(m.4)))
                } else if let m = line.firstMatch(of: timeout), let secs = Int(m.1), !byProcess.isEmpty {
                    byProcess[byProcess.count - 1].timeoutSeconds = secs
                }
            case .none, .kernel:
                break
            }
        }
        return Assertions(systemWide: systemWide, byProcess: byProcess)
    }
}

/// What `pmset -g batt` reports.
public struct BatteryStatus: Equatable, Sendable {
    public var source: PowerSource?
    public var percent: Int?
    public var charging: Bool

    public static func parse(_ text: String) -> BatteryStatus {
        var status = BatteryStatus(source: nil, percent: nil, charging: false)
        if let m = text.firstMatch(of: /Now drawing from '([^']+)'/) {
            status.source = PowerSource(rawValue: String(m.1))
        }
        if let m = text.firstMatch(of: /(\d+)%; ([^;]+);/) {
            status.percent = Int(m.1)
            status.charging = m.2 == "charging"
        }
        return status
    }
}
