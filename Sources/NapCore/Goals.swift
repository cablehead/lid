import Foundation

/// Something the user may want, and the `pmset` change that gets it.
public struct Goal: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case neverIdleSleep
        case idleSleepAfter
    }

    public var source: PowerSource
    public var kind: Kind
    /// Minutes, for `.idleSleepAfter`.
    public var minutes: Int

    public init(source: PowerSource, kind: Kind, minutes: Int = 10) {
        self.source = source
        self.kind = kind
        self.minutes = minutes
    }

    public var id: String { "\(source.rawValue)-\(kind.rawValue)" }

    /// The goals the window offers.
    public static let all: [Goal] = [
        Goal(source: .ac, kind: .neverIdleSleep),
        Goal(source: .ac, kind: .idleSleepAfter, minutes: 30),
        Goal(source: .battery, kind: .neverIdleSleep),
        Goal(source: .battery, kind: .idleSleepAfter, minutes: 10),
    ]

    public static let minuteRange = 1...180

    public var title: String {
        switch kind {
        case .neverIdleSleep: "\(source.label): never sleep when idle"
        case .idleSleepAfter: "\(source.label): sleep after \(Explain.minutes(minutes)) idle"
        }
    }

    /// The settings it changes, as `key value` pairs, in order.
    public var changes: [(key: String, value: Int)] {
        switch kind {
        case .neverIdleSleep:
            [("sleep", 0)]
        case .idleSleepAfter:
            // The Mac only idle-sleeps once the display is off, so both are set.
            [("displaysleep", minutes), ("sleep", minutes)]
        }
    }

    /// A one-line note on why, when it is not obvious.
    public var note: String? {
        switch kind {
        case .neverIdleSleep: nil
        case .idleSleepAfter: "Sets the display too: the Mac only idle-sleeps once the display is off."
        }
    }

    /// The arguments to `/usr/bin/pmset`.
    public var pmsetArguments: [String] {
        [source.flag] + changes.flatMap { [$0.key, String($0.value)] }
    }

    /// What the user would type in Terminal.
    public var command: String {
        "sudo pmset " + pmsetArguments.joined(separator: " ")
    }

    /// The shell line run as root by the admin prompt.
    public var rootShell: String {
        "/usr/bin/pmset " + pmsetArguments.joined(separator: " ")
    }

    /// Whether the current settings already do this.
    public func isMet(by settings: PowerSettings) -> Bool {
        guard let s = settings.sources[source] else { return false }
        return changes.allSatisfy { s.int($0.key) == $0.value }
    }
}
