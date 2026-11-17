import Foundation

/// A lid-open choice for one power source, and the `pmset` change that gets it.
public struct Goal: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case neverIdleSleep
        case idleSleepAfter
        /// macOS's own settings for this source.
        case macDefault
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

    public static let minuteRange = 1...180

    /// The settings it changes, as `key value` pairs, in order.
    public var changes: [(key: String, value: Int)] {
        switch kind {
        case .neverIdleSleep:
            [("sleep", 0)]
        case .idleSleepAfter:
            // The Mac only idle-sleeps once the display is off, so both are set.
            [("displaysleep", minutes), ("sleep", minutes)]
        case .macDefault:
            [("displaysleep", Table.defaultIdleMinutes(source)), ("sleep", Table.defaultSleepMinutes)]
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
}
