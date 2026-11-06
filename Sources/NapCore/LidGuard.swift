import Foundation

/// The lid-closed timer, as a pure state machine. The app feeds it events
/// (lid, power, battery, heat, timer, arm/disarm/quit) and runs the actions it
/// returns, in order.
///
/// Rules:
/// - Armed: `disablesleep 1` is set, so closing the lid does not sleep the Mac.
/// - Lid closed on battery: the countdown runs. Lid opened: it is cancelled,
///   and the next close gets the full time again.
/// - Lid closed and plugged in: the Mac stays awake and the countdown pauses;
///   unplugging resumes it with the time that was left.
/// - Time up, too hot (serious or critical), or battery under the floor while
///   the lid is closed: `disablesleep 0`, then `sleepnow`. Nap stays armed and
///   sets `disablesleep 1` again the next time the lid opens.
/// - Disarm or quit: `disablesleep 0`, always.
public struct LidGuard: Equatable, Sendable {
    public enum Thermal: Int, Comparable, Sendable {
        case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Event: Equatable, Sendable {
        case arm
        case disarm
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
        case timeUp, hot, batteryLow
    }

    public enum Phase: Equatable, Sendable {
        /// Not armed. Nap leaves sleep alone.
        case off
        /// Armed, lid open: closing it starts the countdown.
        case armed
        /// Lid closed on battery: sleeps at `deadline`.
        case counting(deadline: Date)
        /// Lid closed and plugged in: awake, `remaining` kept for unplugging.
        case pluggedIn(remaining: TimeInterval)
        /// Nap put the Mac to sleep; re-arms when the lid opens.
        case stopped(StopReason)
    }

    public private(set) var phase: Phase = .off
    public private(set) var lidClosed = false
    public private(set) var onBattery = false
    public private(set) var batteryPercent: Int?
    public private(set) var thermal: Thermal = .nominal
    /// How long to stay awake with the lid closed on battery.
    public var duration: TimeInterval
    /// Stop early under this battery percentage.
    public var batteryFloor: Int

    public init(duration: TimeInterval = 3600, batteryFloor: Int = 15,
                lidClosed: Bool = false, onBattery: Bool = false,
                batteryPercent: Int? = nil, thermal: Thermal = .nominal) {
        self.duration = duration
        self.batteryFloor = batteryFloor
        self.lidClosed = lidClosed
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }

    public var isArmed: Bool { phase != .off }

    var tooHot: Bool { thermal >= .serious }
    var batteryLow: Bool { onBattery && (batteryPercent.map { $0 < batteryFloor } ?? false) }

    public mutating func handle(_ event: Event, now: Date) -> [Action] {
        switch event {
        case .arm:
            guard phase == .off else { return [] }
            phase = .armed
            var actions: [Action] = [.disableSleep(true)]
            if lidClosed { actions += lidJustClosed(now: now, remaining: duration) }
            return actions

        case .disarm, .quit:
            guard phase != .off else { return [] }
            phase = .off
            return [.cancelTimer, .disableSleep(false)]

        case .lid(let closed):
            guard closed != lidClosed else { return [] }
            lidClosed = closed
            switch phase {
            case .off:
                return []
            case .armed:
                return closed ? lidJustClosed(now: now, remaining: duration) : []
            case .counting, .pluggedIn:
                // Opened (a close while closed is filtered above).
                phase = .armed
                return [.cancelTimer]
            case .stopped:
                guard !closed else { return [] }
                phase = .armed
                return [.disableSleep(true)]
            }

        case .power(let battery):
            guard battery != onBattery else { return [] }
            onBattery = battery
            switch phase {
            case .counting(let deadline) where !battery:
                phase = .pluggedIn(remaining: max(0, deadline.timeIntervalSince(now)))
                return [.cancelTimer]
            case .pluggedIn(let remaining) where battery:
                return lidJustClosed(now: now, remaining: remaining)
            default:
                return []
            }

        case .battery(let percent):
            batteryPercent = percent
            return checkSafety()

        case .thermal(let level):
            thermal = level
            return checkSafety()

        case .timerFired:
            guard case .counting = phase else { return [] }
            return stop(.timeUp)
        }
    }

    /// The lid is closed (or the Mac went to battery with it closed).
    private mutating func lidJustClosed(now: Date, remaining: TimeInterval) -> [Action] {
        if tooHot { return stop(.hot) }
        if batteryLow { return stop(.batteryLow) }
        if !onBattery {
            phase = .pluggedIn(remaining: remaining)
            return []
        }
        if remaining <= 0 { return stop(.timeUp) }
        phase = .counting(deadline: now.addingTimeInterval(remaining))
        return [.startTimer(seconds: remaining)]
    }

    private mutating func checkSafety() -> [Action] {
        switch phase {
        case .counting, .pluggedIn:
            if tooHot { return stop(.hot) }
            if batteryLow { return stop(.batteryLow) }
            return []
        default:
            return []
        }
    }

    private mutating func stop(_ reason: StopReason) -> [Action] {
        phase = .stopped(reason)
        return [.cancelTimer, .disableSleep(false), .sleepNow]
    }

    /// A short status line for the menu.
    public func status(now: Date) -> String {
        switch phase {
        case .off:
            return "Off: closing the lid puts the Mac to sleep at once, as usual"
        case .armed:
            return "Armed: lid closed on battery stays awake \(Explain.minutes(Int(duration / 60)))"
        case .counting(let deadline):
            let left = max(0, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
            return "Lid closed: sleeping in \(Explain.minutes(left))"
        case .pluggedIn:
            return "Lid closed, plugged in: staying awake"
        case .stopped(let reason):
            let why = switch reason {
            case .timeUp: "time was up"
            case .hot: "the Mac got hot"
            case .batteryLow: "battery was under \(batteryFloor)%"
            }
            return "Put to sleep (\(why)). Re-arms when the lid opens"
        }
    }
}
