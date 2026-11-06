import Foundation

/// What the Mac does with the lid closed, on one power source.
public enum LidRule: Equatable, Sendable {
    /// macOS's own behaviour: sleep at once.
    case sleep
    /// Stay awake this many minutes after the lid closes, then sleep.
    /// nil: stay awake as long as the lid is closed.
    case stayAwake(minutes: Int?)

    public var staysAwake: Bool { self != .sleep }

    /// Stored form for UserDefaults: "sleep", "awake", "awake:60".
    public var stored: String {
        switch self {
        case .sleep: "sleep"
        case .stayAwake(nil): "awake"
        case .stayAwake(let m?): "awake:\(m)"
        }
    }

    public init?(stored: String) {
        if stored == "sleep" { self = .sleep; return }
        if stored == "awake" { self = .stayAwake(minutes: nil); return }
        guard stored.hasPrefix("awake:"), let m = Int(stored.dropFirst(6)), m > 0 else { return nil }
        self = .stayAwake(minutes: m)
    }
}

/// The lid-closed rules, as a pure state machine. The app feeds it events
/// (lid, power, battery, heat, timer, rule changes, quit) and runs the actions
/// it returns, in order.
///
/// - Lid open: `disablesleep 1` is held exactly when the current power
///   source's rule is to stay awake (it must already be set when the lid
///   closes, or macOS sleeps at once).
/// - Lid closed with a stay-awake rule: awake until `closedAt + minutes` of
///   the current source's rule. When the power source changes, the new
///   source's rule applies, still counted from the lid close; a `.sleep` rule
///   or a time already past sleeps at once.
/// - Too hot (serious or critical), or on battery under the floor, while the
///   lid is closed: sleep.
/// - Sleep means `disablesleep 0`, then `pmset sleepnow`. When the lid opens,
///   `disablesleep` goes back to what the rule wants.
/// - Quit: `disablesleep 0` if Nap set it.
public struct LidGuard: Equatable, Sendable {
    public enum Thermal: Int, Comparable, Sendable {
        case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Event: Equatable, Sendable {
        case setRule(PowerSource, LidRule)
        case quit
        case lid(closed: Bool)
        case power(onBattery: Bool)
        case battery(percent: Int)
        case thermal(Thermal)
        case timerFired
    }

    public enum Action: Equatable, Sendable {
        case disableSleep(Bool)
        case sleepNow
        case startTimer(seconds: TimeInterval)
        case cancelTimer

        /// The `pmset` command line, for actions that run one.
        public var pmset: String? {
            switch self {
            case .disableSleep(let on): "/usr/bin/pmset -a disablesleep \(on ? 1 : 0)"
            case .sleepNow: "/usr/bin/pmset sleepnow"
            case .startTimer, .cancelTimer: nil
            }
        }
    }

    public enum StopReason: Equatable, Sendable {
        case timeUp, hot, batteryLow, rule
    }

    public enum Phase: Equatable, Sendable {
        /// Lid open, or closed with Nap doing nothing (macOS's own behaviour).
        case idle
        /// Lid closed and kept awake by Nap. `deadline` nil: no time limit.
        case awake(closedAt: Date, deadline: Date?)
        /// Nap put the Mac to sleep with the lid closed.
        case stopped(StopReason)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var rules: [PowerSource: LidRule]
    /// True while Nap holds `disablesleep 1`.
    public private(set) var sleepDisabled: Bool
    public private(set) var lidClosed: Bool
    public private(set) var onBattery: Bool
    public private(set) var batteryPercent: Int?
    public private(set) var thermal: Thermal
    /// Sleep early under this battery percentage (lid closed, on battery).
    public var batteryFloor: Int

    /// `sleepDisabled`: Nap set `disablesleep 1` earlier and it is still set
    /// (after a crash), so `start` can put it back.
    public init(rules: [PowerSource: LidRule] = [:], batteryFloor: Int = 15,
                sleepDisabled: Bool = false, lidClosed: Bool = false, onBattery: Bool = false,
                batteryPercent: Int? = nil, thermal: Thermal = .nominal) {
        self.rules = rules
        self.batteryFloor = batteryFloor
        self.sleepDisabled = sleepDisabled
        self.lidClosed = lidClosed
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }

    public var source: PowerSource { onBattery ? .battery : .ac }
    public func rule(_ source: PowerSource) -> LidRule { rules[source] ?? .sleep }
    public var currentRule: LidRule { rule(source) }

    var tooHot: Bool { thermal >= .serious }
    var batteryLow: Bool { onBattery && (batteryPercent.map { $0 < batteryFloor } ?? false) }

    /// At launch: with the lid open, hold or release sleep for the current rule.
    public mutating func start() -> [Action] {
        lidClosed ? [] : holdForCurrentRule()
    }

    public mutating func handle(_ event: Event, now: Date) -> [Action] {
        switch event {
        case .setRule(let source, let rule):
            rules[source] = rule
            if !lidClosed { return holdForCurrentRule() }
            if case .awake(let closedAt, _) = phase { return keepAwake(closedAt: closedAt, now: now) }
            return []

        case .quit:
            let actions: [Action] = sleepDisabled ? [.cancelTimer, .disableSleep(false)] : [.cancelTimer]
            sleepDisabled = false
            phase = .idle
            return actions

        case .lid(let closed):
            guard closed != lidClosed else { return [] }
            lidClosed = closed
            if closed {
                // Nap only acts if it held sleep off; otherwise macOS sleeps.
                guard sleepDisabled else { return [] }
                return keepAwake(closedAt: now, now: now)
            }
            let wasAwake = phase != .idle
            phase = .idle
            return (wasAwake ? [.cancelTimer] : []) + holdForCurrentRule()

        case .power(let battery):
            guard battery != onBattery else { return [] }
            onBattery = battery
            if !lidClosed { return holdForCurrentRule() }
            if case .awake(let closedAt, _) = phase { return keepAwake(closedAt: closedAt, now: now) }
            return []

        case .battery(let percent):
            batteryPercent = percent
            return checkSafety()

        case .thermal(let level):
            thermal = level
            return checkSafety()

        case .timerFired:
            guard case .awake(_, let deadline?) = phase else { return [] }
            // A timer left from an earlier rule can be stale: trust the deadline.
            if deadline.timeIntervalSince(now) > 1 { return [] }
            return stop(.timeUp)
        }
    }

    /// Lid open: hold `disablesleep 1` exactly when the current rule stays awake.
    private mutating func holdForCurrentRule() -> [Action] {
        let want = currentRule.staysAwake
        guard want != sleepDisabled else { return [] }
        sleepDisabled = want
        return [.disableSleep(want)]
    }

    /// Lid closed, Nap holding sleep off: apply the current source's rule.
    private mutating func keepAwake(closedAt: Date, now: Date) -> [Action] {
        if tooHot { return stop(.hot) }
        if batteryLow { return stop(.batteryLow) }
        switch currentRule {
        case .sleep:
            return stop(.rule)
        case .stayAwake(nil):
            phase = .awake(closedAt: closedAt, deadline: nil)
            return [.cancelTimer]
        case .stayAwake(let minutes?):
            let deadline = closedAt.addingTimeInterval(TimeInterval(minutes * 60))
            let left = deadline.timeIntervalSince(now)
            if left <= 0 { return stop(.timeUp) }
            phase = .awake(closedAt: closedAt, deadline: deadline)
            return [.startTimer(seconds: left)]
        }
    }

    private mutating func checkSafety() -> [Action] {
        guard case .awake = phase else { return [] }
        if tooHot { return stop(.hot) }
        if batteryLow { return stop(.batteryLow) }
        return []
    }

    private mutating func stop(_ reason: StopReason) -> [Action] {
        phase = .stopped(reason)
        sleepDisabled = false
        return [.cancelTimer, .disableSleep(false), .sleepNow]
    }
}
