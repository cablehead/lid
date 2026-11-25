import Foundation
import Testing
@testable import LidCore

/// Drives a LidGuard with times in minutes from a fixed start.
private struct Run {
    var g: LidGuard
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init(battery: LidRule = .stayAwake(minutes: 60), ac: LidRule = .sleep, onBattery: Bool = true,
         percent: Int = 80, lidClosed: Bool = false, thermal: LidGuard.Thermal = .nominal,
         sleepDisabled: Bool = false) {
        g = LidGuard(rules: [.battery: battery, .ac: ac], batteryFloor: 15, sleepDisabled: sleepDisabled,
                     lidClosed: lidClosed, onBattery: onBattery, batteryPercent: percent, thermal: thermal)
    }

    func at(_ minute: Double) -> Date { t0.addingTimeInterval(minute * 60) }

    mutating func send(_ event: LidGuard.Event, at minute: Double = 0) -> [LidGuard.Action] {
        g.handle(event, now: at(minute))
    }
}

private let sleepActions: [LidGuard.Action] = [.cancelTimer, .disableSleep(false), .sleepNow]

@Suite struct LidGuardTests {
    // MARK: Holding disablesleep with the lid open

    @Test func startHoldsSleepOffOnlyForAStayAwakeRule() {
        var r = Run()
        #expect(r.g.start() == [.disableSleep(true)])
        var plain = Run(battery: .sleep)
        #expect(plain.g.start() == [])
        var onAC = Run(onBattery: false)
        #expect(onAC.g.start() == [])  // the AC rule is sleep
    }

    @Test func startPutsSleepBackAfterACrash() {
        var r = Run(battery: .sleep, sleepDisabled: true)
        #expect(r.g.start() == [.disableSleep(false)])
    }

    @Test func defaultRulesNeverTouchSleep() {
        var r = Run(battery: .sleep)
        _ = r.g.start()
        #expect(r.send(.lid(closed: true)) == [])  // macOS sleeps on its own
        #expect(r.send(.thermal(.critical)) == [])
        #expect(r.send(.battery(percent: 2)) == [])
        #expect(r.send(.power(onBattery: false)) == [])
        #expect(r.send(.lid(closed: false)) == [])
        #expect(r.send(.timerFired) == [])
        #expect(r.send(.quit) == [.cancelTimer])  // never touches a disablesleep it did not set
    }

    @Test func settingARuleHoldsOrReleasesForTheCurrentSource() {
        var r = Run(battery: .sleep)
        _ = r.g.start()
        #expect(r.send(.setRule(.ac, .stayAwake(minutes: nil))) == [])  // on battery now
        #expect(r.send(.setRule(.battery, .stayAwake(minutes: 30))) == [.disableSleep(true)])
        #expect(r.send(.setRule(.battery, .stayAwake(minutes: 45))) == [])
        #expect(r.send(.setRule(.battery, .sleep)) == [.disableSleep(false)])
    }

    @Test func powerChangesWithLidOpenFollowEachSourcesRule() {
        var r = Run()  // battery: 60 min, AC: sleep
        _ = r.g.start()
        #expect(r.send(.power(onBattery: false)) == [.disableSleep(false)])
        #expect(r.send(.power(onBattery: false)) == [])
        #expect(r.send(.power(onBattery: true)) == [.disableSleep(true)])
    }

    // MARK: Lid closed on battery

    @Test func fullHourThenSleep() {
        var r = Run()
        _ = r.g.start()
        #expect(r.send(.lid(closed: true), at: 1) == [.startTimer(seconds: 3600)])
        #expect(r.g.phase == .awake(closedAt: r.at(1), since: r.at(1), deadline: r.at(61)))
        #expect(r.send(.timerFired, at: 61) == sleepActions)
        #expect(r.g.phase == .stopped(.timeUp))
        #expect(!r.g.sleepDisabled)
    }

    @Test func lidOpensBeforeTheHourCancels() {
        var r = Run()
        _ = r.g.start()
        _ = r.send(.lid(closed: true), at: 0)
        #expect(r.send(.lid(closed: false), at: 20) == [.cancelTimer])  // sleep stays held off
        #expect(r.g.phase == .idle)
        #expect(r.send(.timerFired, at: 60) == [])  // stale
        #expect(r.send(.lid(closed: true), at: 30) == [.startTimer(seconds: 3600)])  // full hour again
    }

    @Test func reHoldsWhenLidOpensAfterSleeping() {
        var r = Run()
        _ = r.g.start()
        _ = r.send(.lid(closed: true))
        _ = r.send(.timerFired, at: 60)
        #expect(r.send(.battery(percent: 50), at: 120) == [])  // dark wake in the bag
        #expect(r.send(.power(onBattery: false), at: 121) == [])  // asleep: no rule switch
        _ = r.send(.power(onBattery: true), at: 122)
        #expect(r.send(.lid(closed: false), at: 600) == [.cancelTimer, .disableSleep(true)])
        #expect(r.send(.lid(closed: true), at: 601) == [.startTimer(seconds: 3600)])
    }

    // MARK: Power source changes with the lid closed

    @Test func pluggedInMidwaySwitchesToThePluggedInRule() {
        var r = Run(ac: .stayAwake(minutes: nil))
        _ = r.g.start()
        _ = r.send(.lid(closed: true), at: 0)
        #expect(r.send(.power(onBattery: false), at: 20) == [.cancelTimer])
        #expect(r.g.phase == .awake(closedAt: r.at(0), since: r.at(20), deadline: nil))
        #expect(r.send(.battery(percent: 5), at: 25) == [])  // plugged in: battery does not matter
        _ = r.send(.battery(percent: 70), at: 26)
        // Unplugged again: a fresh battery hour, from the unplug.
        #expect(r.send(.power(onBattery: true), at: 30) == [.startTimer(seconds: 60 * 60)])
        #expect(r.send(.timerFired, at: 60) == [])  // stale timer from the first hour
        #expect(r.send(.timerFired, at: 90) == sleepActions)
    }

    @Test func pluggedInRuleWithItsOwnTime() {
        var r = Run(ac: .stayAwake(minutes: 90))
        _ = r.g.start()
        _ = r.send(.lid(closed: true), at: 0)
        #expect(r.send(.power(onBattery: false), at: 20) == [.startTimer(seconds: 90 * 60)])
        // The battery timer, set for minute 60, fires stale: ignored.
        #expect(r.send(.timerFired, at: 60) == [])
        #expect(r.send(.timerFired, at: 110) == sleepActions)
    }

    @Test func pluggedInStartsItsTimeFresh() {
        // 20 minutes on battery would have used up a 15-minute plugged-in
        // time counted from the close; counted from the plug-in, it has all 15.
        var r = Run(ac: .stayAwake(minutes: 15))
        _ = r.g.start()
        _ = r.send(.lid(closed: true), at: 0)
        #expect(r.send(.power(onBattery: false), at: 20) == [.startTimer(seconds: 15 * 60)])
        #expect(r.send(.timerFired, at: 35) == sleepActions)
        #expect(r.g.phase == .stopped(.timeUp))
    }

    @Test func pluggedInWithASleepRuleSleeps() {
        var r = Run(ac: .sleep)
        _ = r.g.start()
        _ = r.send(.lid(closed: true), at: 0)
        #expect(r.send(.power(onBattery: false), at: 5) == sleepActions)
        #expect(r.g.phase == .stopped(.rule))
    }

    @Test func unpluggedLongAfterTheCloseGetsTheWholeBatteryHour() {
        var r = Run(ac: .stayAwake(minutes: nil), onBattery: false)
        _ = r.g.start()
        #expect(r.send(.lid(closed: true), at: 0) == [.cancelTimer])
        #expect(r.send(.power(onBattery: true), at: 120) == [.startTimer(seconds: 60 * 60)])
        #expect(r.send(.timerFired, at: 180) == sleepActions)
    }

    @Test func movingBetweenChargersRestartsEachTime() {
        // A day plugged in, an hour on battery: closed on power for 12 hours,
        // unplugged for a 30-minute move, then plugged in again.
        var r = Run(battery: .stayAwake(minutes: 60), ac: .stayAwake(minutes: 1440), onBattery: false)
        _ = r.g.start()
        #expect(r.send(.lid(closed: true), at: 0) == [.startTimer(seconds: 1440 * 60)])
        #expect(r.send(.power(onBattery: true), at: 720) == [.startTimer(seconds: 60 * 60)])
        #expect(r.g.phase == .awake(closedAt: r.at(0), since: r.at(720), deadline: r.at(780)))
        #expect(r.send(.power(onBattery: false), at: 750) == [.startTimer(seconds: 1440 * 60)])
        #expect(r.g.phase == .awake(closedAt: r.at(0), since: r.at(750), deadline: r.at(2190)))
        #expect(r.send(.timerFired, at: 780) == [])  // the battery hour's timer, stale
        #expect(r.send(.timerFired, at: 2190) == sleepActions)
    }

    @Test func unpluggedWithLowBatterySleeps() {
        var r = Run(ac: .stayAwake(minutes: nil), onBattery: false, percent: 10)
        _ = r.g.start()
        _ = r.send(.lid(closed: true))
        #expect(r.send(.power(onBattery: true), at: 5) == sleepActions)
        #expect(r.g.phase == .stopped(.batteryLow))
    }

    // MARK: Early stops

    @Test func seriousHeatStopsEarly() {
        var r = Run()
        _ = r.g.start()
        _ = r.send(.lid(closed: true))
        #expect(r.send(.thermal(.fair), at: 5) == [])
        #expect(r.send(.thermal(.serious), at: 10) == sleepActions)
        #expect(r.g.phase == .stopped(.hot))
        #expect(r.send(.thermal(.critical), at: 11) == [])  // not repeated
    }

    @Test func criticalHeatStopsEvenWhenPluggedIn() {
        var r = Run(ac: .stayAwake(minutes: nil), onBattery: false)
        _ = r.g.start()
        _ = r.send(.lid(closed: true))
        #expect(r.send(.thermal(.critical), at: 10) == sleepActions)
    }

    @Test func heatWithLidOpenWaitsForTheClose() {
        var r = Run()
        _ = r.g.start()
        #expect(r.send(.thermal(.serious)) == [])
        #expect(r.send(.lid(closed: true), at: 1) == sleepActions)
        #expect(r.g.phase == .stopped(.hot))
    }

    @Test func lowBatteryStopsEarly() {
        var r = Run(percent: 40)
        _ = r.g.start()
        _ = r.send(.lid(closed: true))
        #expect(r.send(.battery(percent: 15), at: 35) == [])  // "under 15%"
        #expect(r.send(.battery(percent: 14), at: 40) == sleepActions)
        #expect(r.g.phase == .stopped(.batteryLow))
    }

    @Test func lowBatteryAtTheCloseSleepsAtOnce() {
        var r = Run(percent: 9)
        _ = r.g.start()
        #expect(r.send(.lid(closed: true)) == sleepActions)
    }

    // MARK: Changing rules with the lid closed

    @Test func shorterRuleWhileClosedMayEndAtOnce() {
        var r = Run()
        _ = r.g.start()
        _ = r.send(.lid(closed: true), at: 0)
        #expect(r.send(.setRule(.battery, .stayAwake(minutes: 30)), at: 10) == [.startTimer(seconds: 20 * 60)])
        #expect(r.send(.setRule(.battery, .stayAwake(minutes: 5)), at: 10) == sleepActions)
    }

    @Test func sleepRuleWhileClosedSleeps() {
        var r = Run()
        _ = r.g.start()
        _ = r.send(.lid(closed: true), at: 0)
        #expect(r.send(.setRule(.battery, .sleep), at: 10) == sleepActions)
        #expect(r.g.phase == .stopped(.rule))
    }

    // MARK: Quit

    @Test func quitRestoresDisableSleepWheneverLidHoldsIt() {
        for setup in 0...2 {
            var r = Run(ac: .stayAwake(minutes: nil))
            _ = r.g.start()
            if setup >= 1 { _ = r.send(.lid(closed: true)) }
            if setup == 2 { _ = r.send(.power(onBattery: false), at: 1) }
            #expect(r.send(.quit, at: 5) == [.cancelTimer, .disableSleep(false)], "setup \(setup)")
            #expect(!r.g.sleepDisabled)
            #expect(r.send(.timerFired, at: 60) == [])
        }
    }

    @Test func quitAfterLidPutItToSleepHasNothingToRestore() {
        var r = Run()
        _ = r.g.start()
        _ = r.send(.lid(closed: true))
        _ = r.send(.timerFired, at: 60)
        #expect(r.send(.quit, at: 61) == [.cancelTimer])
    }

    // MARK: Misc

    @Test func repeatedEventsAreIgnored() {
        var r = Run()
        _ = r.g.start()
        _ = r.send(.lid(closed: true))
        #expect(r.send(.lid(closed: true), at: 1) == [])
        #expect(r.send(.power(onBattery: true), at: 2) == [])
        #expect(r.g.phase == .awake(closedAt: r.at(0), since: r.at(0), deadline: r.at(60)))
    }

    @Test func rulesStoreAndLoad() {
        for rule in [LidRule.sleep, .stayAwake(minutes: nil), .stayAwake(minutes: 60)] {
            #expect(LidRule(stored: rule.stored) == rule)
        }
        #expect(LidRule(stored: "awake:0") == nil)
        #expect(LidRule(stored: "nonsense") == nil)
    }

    @Test func everyRootActionIsAllowedBySudoers() {
        for action in [LidGuard.Action.disableSleep(true), .disableSleep(false), .sleepNow] {
            #expect(Sudoers.commands.contains(action.pmset!))
        }
    }
}
