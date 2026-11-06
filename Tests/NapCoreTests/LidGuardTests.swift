import Foundation
import Testing
@testable import NapCore

/// Drives a LidGuard through a script of (minute, event) steps.
private struct Run {
    var guardian: LidGuard
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init(onBattery: Bool = true, percent: Int = 80, lidClosed: Bool = false, thermal: LidGuard.Thermal = .nominal) {
        guardian = LidGuard(duration: 3600, batteryFloor: 15, lidClosed: lidClosed,
                            onBattery: onBattery, batteryPercent: percent, thermal: thermal)
    }

    func at(_ minute: Double) -> Date { start.addingTimeInterval(minute * 60) }

    mutating func send(_ event: LidGuard.Event, at minute: Double = 0) -> [LidGuard.Action] {
        guardian.handle(event, now: at(minute))
    }
}

private let sleepActions: [LidGuard.Action] = [.cancelTimer, .disableSleep(false), .sleepNow]

@Suite struct LidGuardTests {
    @Test func armSetsDisableSleepAndNothingElseWithLidOpen() {
        var r = Run()
        #expect(r.send(.arm) == [.disableSleep(true)])
        #expect(r.guardian.phase == .armed)
        #expect(r.send(.arm) == [])  // already armed
    }

    @Test func offIgnoresEverything() {
        var r = Run()
        #expect(r.send(.lid(closed: true)) == [])
        #expect(r.send(.thermal(.critical)) == [])
        #expect(r.send(.battery(percent: 2)) == [])
        #expect(r.send(.timerFired) == [])
        #expect(r.send(.disarm) == [])
        #expect(r.send(.quit) == [])  // never touches a disablesleep it did not set
        #expect(r.guardian.phase == .off)
    }

    @Test func fullHourThenSleep() {
        var r = Run()
        _ = r.send(.arm)
        #expect(r.send(.lid(closed: true), at: 1) == [.startTimer(seconds: 3600)])
        #expect(r.guardian.phase == .counting(deadline: r.at(61)))
        #expect(r.guardian.status(now: r.at(31)) == "Lid closed: sleeping in 30 minutes")
        #expect(r.send(.timerFired, at: 61) == sleepActions)
        #expect(r.guardian.phase == .stopped(.timeUp))
        #expect(r.guardian.isArmed)
    }

    @Test func lidOpensBeforeTheHourCancels() {
        var r = Run()
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true), at: 0)
        #expect(r.send(.lid(closed: false), at: 20) == [.cancelTimer])
        #expect(r.guardian.phase == .armed)
        // A stale timer firing after the cancel does nothing.
        #expect(r.send(.timerFired, at: 60) == [])
        // The next close gets the full hour again.
        #expect(r.send(.lid(closed: true), at: 30) == [.startTimer(seconds: 3600)])
    }

    @Test func pluggedInMidwayPausesThenResumesWithTimeLeft() {
        var r = Run()
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true), at: 0)
        #expect(r.send(.power(onBattery: false), at: 20) == [.cancelTimer])
        #expect(r.guardian.phase == .pluggedIn(remaining: 40 * 60))
        #expect(r.guardian.status(now: r.at(25)) == "Lid closed, plugged in: staying awake")
        // Battery level and stale timers do not matter while plugged in.
        #expect(r.send(.battery(percent: 5), at: 30) == [])
        #expect(r.send(.timerFired, at: 60) == [])
        _ = r.send(.battery(percent: 70), at: 90)
        #expect(r.send(.power(onBattery: true), at: 100) == [.startTimer(seconds: 40 * 60)])
        #expect(r.guardian.phase == .counting(deadline: r.at(140)))
        #expect(r.send(.timerFired, at: 140) == sleepActions)
    }

    @Test func lidClosedWhilePluggedInStaysAwakeUntilUnplugged() {
        var r = Run(onBattery: false)
        _ = r.send(.arm)
        #expect(r.send(.lid(closed: true), at: 0) == [])
        #expect(r.guardian.phase == .pluggedIn(remaining: 3600))
        #expect(r.send(.power(onBattery: true), at: 300) == [.startTimer(seconds: 3600)])
    }

    @Test func unpluggedWithLowBatteryWhileLidClosedSleeps() {
        var r = Run(onBattery: false, percent: 10)
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true))
        #expect(r.send(.power(onBattery: true), at: 5) == sleepActions)
        #expect(r.guardian.phase == .stopped(.batteryLow))
    }

    @Test func pluggedInThenLidOpenedReturnsToArmed() {
        var r = Run()
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true))
        _ = r.send(.power(onBattery: false), at: 10)
        #expect(r.send(.lid(closed: false), at: 20) == [.cancelTimer])
        #expect(r.guardian.phase == .armed)
    }

    @Test func seriousHeatStopsEarly() {
        var r = Run()
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true))
        #expect(r.send(.thermal(.fair), at: 5) == [])
        #expect(r.send(.thermal(.serious), at: 10) == sleepActions)
        #expect(r.guardian.phase == .stopped(.hot))
        #expect(r.guardian.status(now: r.at(10)).contains("got hot"))
        // Already stopped: more heat does not repeat the actions.
        #expect(r.send(.thermal(.critical), at: 11) == [])
    }

    @Test func criticalHeatStopsEvenWhenPluggedIn() {
        var r = Run(onBattery: false)
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true))
        #expect(r.send(.thermal(.critical), at: 10) == sleepActions)
    }

    @Test func heatWithLidOpenWaitsUntilClose() {
        var r = Run()
        _ = r.send(.arm)
        #expect(r.send(.thermal(.serious)) == [])
        #expect(r.guardian.phase == .armed)
        #expect(r.send(.lid(closed: true), at: 1) == sleepActions)
        #expect(r.guardian.phase == .stopped(.hot))
    }

    @Test func lowBatteryStopsEarly() {
        var r = Run(percent: 40)
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true))
        #expect(r.send(.battery(percent: 16), at: 30) == [])
        #expect(r.send(.battery(percent: 15), at: 35) == [])  // floor is "below 15%"
        #expect(r.send(.battery(percent: 14), at: 40) == sleepActions)
        #expect(r.guardian.phase == .stopped(.batteryLow))
        #expect(r.guardian.status(now: r.at(40)).contains("under 15%"))
    }

    @Test func lowBatteryAtCloseSleepsAtOnce() {
        var r = Run(percent: 9)
        _ = r.send(.arm)  // lid open: low battery alone is not a reason
        #expect(r.guardian.phase == .armed)
        #expect(r.send(.lid(closed: true)) == sleepActions)
    }

    @Test func reArmsWhenLidOpensAfterStop() {
        var r = Run()
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true))
        _ = r.send(.timerFired, at: 60)
        // A dark wake in the bag (lid still closed) changes nothing.
        #expect(r.send(.battery(percent: 50), at: 120) == [])
        #expect(r.send(.lid(closed: false), at: 600) == [.disableSleep(true)])
        #expect(r.guardian.phase == .armed)
        #expect(r.send(.lid(closed: true), at: 601) == [.startTimer(seconds: 3600)])
    }

    @Test func disarmWhileCountingRestores() {
        var r = Run()
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true))
        #expect(r.send(.disarm, at: 5) == [.cancelTimer, .disableSleep(false)])
        #expect(r.guardian.phase == .off)
        #expect(r.send(.timerFired, at: 60) == [])
        #expect(r.send(.lid(closed: false), at: 61) == [])
    }

    @Test func quitWhileArmedRestoresDisableSleep() {
        for setup in [0, 1, 2, 3] {
            var r = Run()
            _ = r.send(.arm)
            if setup >= 1 { _ = r.send(.lid(closed: true)) }
            if setup == 2 { _ = r.send(.power(onBattery: false), at: 1) }
            if setup == 3 { _ = r.send(.timerFired, at: 60) }
            let actions = r.send(.quit, at: 61)
            #expect(actions.last == .disableSleep(false), "setup \(setup)")
            #expect(r.guardian.phase == .off)
        }
    }

    @Test func armWithLidAlreadyClosedOnBatteryStartsCounting() {
        var r = Run(lidClosed: true)
        #expect(r.send(.arm) == [.disableSleep(true), .startTimer(seconds: 3600)])
    }

    @Test func armWhenHotWithLidClosedEndsAtOnce() {
        var r = Run(lidClosed: true, thermal: .serious)
        #expect(r.send(.arm) == [.disableSleep(true)] + sleepActions)
    }

    @Test func repeatedLidAndPowerEventsAreIgnored() {
        var r = Run()
        _ = r.send(.arm)
        _ = r.send(.lid(closed: true))
        #expect(r.send(.lid(closed: true), at: 1) == [])
        #expect(r.send(.power(onBattery: true), at: 2) == [])
        #expect(r.guardian.phase == .counting(deadline: r.at(60)))
    }

    @Test func customDuration() {
        var r = Run()
        r.guardian.duration = 15 * 60
        _ = r.send(.arm)
        #expect(r.guardian.status(now: r.at(0)) == "Armed: lid closed on battery stays awake 15 minutes")
        #expect(r.send(.lid(closed: true)) == [.startTimer(seconds: 900)])
    }

    @Test func everyRootActionIsAllowedBySudoers() {
        for action in [LidGuard.Action.disableSleep(true), .disableSleep(false), .sleepNow] {
            #expect(Sudoers.commands.contains(action.pmset!))
        }
    }
}
