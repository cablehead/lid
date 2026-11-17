import Testing
import Foundation
@testable import ClamshellCore

@Suite struct PmsetTests {
    let settings = PowerSettings.parse(custom: Fixture.text("pmset-custom"), systemWide: Fixture.text("pmset-g"))

    @Test func parsesBothSourcesFromThisMac() {
        #expect(settings.sources.keys.sorted { $0.rawValue < $1.rawValue } == [.ac, .battery])
        for source in [PowerSource.ac, .battery] {
            #expect(settings.sources[source]?.sleep == 1)
            #expect(settings.sources[source]?.displaySleep == 0)
            #expect(settings.sources[source]?.int("disksleep") == 10)
        }
        #expect(settings.sources[.ac]?.values["womp"] == "1")
        #expect(settings.sources[.battery]?.values["womp"] == "0")
        #expect(settings.sources[.battery]?.values["Sleep On Power Button"] == "1")
        #expect(settings.sources[.ac]?.values["hibernatefile"] == "/var/vm/sleepimage")
        #expect(settings.sleepDisabled == false)
    }

    @Test func readsSleepDisabled() {
        #expect(PowerSettings.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\n") == true)
        #expect(PowerSettings.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t0\n") == false)
        #expect(PowerSettings.parseSleepDisabled("") == false)
    }

    @Test func parsesAssertionsFromThisMac() {
        let a = Assertions.parse(Fixture.text("pmset-assertions"))
        #expect(a.systemWide["PreventUserIdleSystemSleep"] == 1)
        #expect(a.systemWide["UserIsActive"] == 1)
        #expect(a.systemWide["PreventSystemSleepSecurityIndicator"] == 0)
        #expect(a.byProcess.count == 9)
        let caffeinate = a.byProcess.first { $0.process == "caffeinate" }
        #expect(caffeinate?.timeoutSeconds == 94)
        #expect(caffeinate?.type == "PreventUserIdleSystemSleep")
        #expect(a.byProcess.first { $0.process == "apsd" }?.timeoutSeconds == 1)
        #expect(a.byProcess.first { $0.process == "mds_stores" }?.timeoutSeconds == nil)
        #expect(a.keepingAwake.map(\.process) == ["runningboardd", "sharingd", "powerd", "caffeinate"])
    }

    @Test func parsesBatteryFromThisMac() {
        let b = BatteryStatus.parse(Fixture.text("pmset-batt"))
        #expect(b == BatteryStatus(source: .ac, percent: 24, charging: true))
        let onBattery = BatteryStatus.parse("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%; discharging; 5:00 remaining present: true\n")
        #expect(onBattery == BatteryStatus(source: .battery, percent: 80, charging: false))
    }
}

@Suite struct TableTests {
    let settings = PowerSettings.parse(custom: Fixture.text("pmset-custom"), systemWide: Fixture.text("pmset-g"))

    func open(_ source: PowerSource, _ rule: LidRule = .sleep, foreign: Bool = false) -> Table.Cell {
        Table.openCell(source, settings: settings, rule: rule, foreignDisableSleep: foreign)
    }

    @Test func thisMacWithLidOpen() {
        // sleep 1 + displaysleep 0: never idle-sleeps, the display stays on.
        for source in [PowerSource.ac, .battery] {
            #expect(open(source) == Table.Cell(
                text: "never sleeps (display stays on)",
                detail: "set to sleep after 1 min, but the display never turns off, so it never gets there",
                isDefault: false))
        }
    }

    @Test func thisMacWithLidClosed() {
        for source in [PowerSource.ac, .battery] {
            #expect(Table.closedCell(source, rule: .sleep, batteryFloor: 15, foreignDisableSleep: false)
                == Table.Cell(text: "sleeps at once", detail: nil, isDefault: true))
        }
    }

    @Test func lidClosedRules() {
        #expect(Table.closedCell(.battery, rule: .stayAwake(minutes: 60), batteryFloor: 15, foreignDisableSleep: false)
            == Table.Cell(text: "stays awake 1 hour, then sleeps", detail: "sleeps early if hot or battery under 15%", isDefault: false))
        #expect(Table.closedCell(.ac, rule: .stayAwake(minutes: nil), batteryFloor: 15, foreignDisableSleep: false)
            == Table.Cell(text: "stays awake", detail: "sleeps early if hot", isDefault: false))
        #expect(Table.closedCell(.ac, rule: .sleep, batteryFloor: 15, foreignDisableSleep: true).text
            == "stays awake (disablesleep 1)")
    }

    @Test func idleCases() {
        func cell(_ sleep: Int, _ display: Int, _ source: PowerSource = .ac, rule: LidRule = .sleep) -> Table.Cell {
            let s = PowerSettings(sources: [source: SourceSettings(["sleep": "\(sleep)", "displaysleep": "\(display)"])])
            return Table.openCell(source, settings: s, rule: rule, foreignDisableSleep: false)
        }
        #expect(cell(1, 10) == Table.Cell(text: "sleeps after 10 min idle", detail: nil, isDefault: true))
        #expect(cell(30, 10).detail == "display turns off after 10 min")
        #expect(cell(0, 0).detail == nil)
        #expect(cell(1, 10, rule: .stayAwake(minutes: 5)).detail == "Clamshell keeps sleep off so the lid can close awake")
        #expect(cell(1, 2, .battery).isDefault)
        #expect(!cell(1, 10, .battery).isDefault)
        #expect(cell(30, 10).text == "sleeps after 30 min idle")
        #expect(!cell(30, 10).isDefault)
        #expect(cell(0, 10).text == "never sleeps (display off after 10 min)")
        #expect(cell(0, 0).text == "never sleeps (display stays on)")
        // A stay-awake lid rule holds disablesleep 1, so idle sleep stops too.
        #expect(cell(1, 10, rule: .stayAwake(minutes: 60)).text == "never sleeps (held by the lid rule)")
        #expect(!cell(1, 10, rule: .stayAwake(minutes: 60)).isDefault)
        #expect(open(.ac, foreign: true).text == "never sleeps (disablesleep 1)")
    }

    @Test func awakeLinesFromThisMac() {
        let a = Assertions.parse(Fixture.text("pmset-assertions"))
        #expect(Table.awakeLines(a) == [
            "Mail, Calendar and Contacts syncing",
            "Handoff: passing work between this Mac and a nearby iPhone or iPad",
            "a caffeinate command, run from a terminal or by an app, 2 min left",
        ])
        #expect(Table.awakeLines(Assertions()) == [])
    }

    func line(_ process: String, _ name: String, timeout: Int? = nil) -> String {
        Table.awakeLines(Assertions(byProcess: [Assertion(pid: 1, process: process, type: "PreventUserIdleSystemSleep",
                                                          name: name, timeoutSeconds: timeout)]))[0]
    }

    @Test func plainNamesForJargon() {
        #expect(line("sharingd", "BTLEAdvertisement.D3EA10B4-4C2B-4F0E-9A51-2B7C1D0E9F33") == "Bluetooth advertising to nearby devices")
        #expect(line("rapportd", "BTLEAdvertisement.D3EA10B4") == "Bluetooth advertising to nearby devices")
        #expect(line("Siri AI", "UIIntelligenceSupport") == "Siri / Apple Intelligence")
        #expect(line("AddressBookSourceSync", "Address Book Source Sync", timeout: 1792) == "Contacts syncing, 30 min left")
    }

    @Test func unknownAppsLoseMachineIDs() {
        #expect(line("SomeAgent", "SyncTask.3F2504E0-4F89-11D3-9A0C-0305E82C3301") == "SomeAgent (an app or service)")
        #expect(line("SomeAgent", "com.example.worker.0x7fa3b2c1") == "SomeAgent (an app or service)")
        #expect(line("SomeAgent", "Uploading photos 9f8e7d6c5b4a") == "SomeAgent (an app or service, for \"Uploading photos\")")
        #expect(line("SomeAgent", "SomeAgent") == "SomeAgent (an app or service)")
        #expect(line("SomeAgent", "", timeout: 30) == "SomeAgent (an app or service), 1 min left")
    }

    @Test func machineIDStripping() {
        #expect(Table.withoutMachineIDs("BTLEAdvertisement.D3EA10B4-4C2B-4F0E-9A51-2B7C1D0E9F33") == "BTLEAdvertisement")
        #expect(Table.withoutMachineIDs("task 0xdeadbeef done") == "task done")
        #expect(Table.withoutMachineIDs("Address Book Source Sync") == "Address Book Source Sync")
        #expect(Table.withoutMachineIDs("facade") == "facade")  // a word, no digit
    }

    @Test func barOnlyWhileAwakeWithLidClosed() {
        let utc = TimeZone(identifier: "UTC")!
        let closed = Date(timeIntervalSince1970: 14 * 3600 + 2 * 60)
        var g = LidGuard(rules: [.battery: .stayAwake(minutes: 60), .ac: .stayAwake(minutes: nil)],
                         onBattery: true, batteryPercent: 80)
        #expect(Table.bar(g, timeZone: utc) == nil)
        _ = g.start()
        _ = g.handle(.lid(closed: true), now: closed)
        #expect(Table.bar(g, timeZone: utc) == ["Closed 14:02 → sleeps 15:02", "Sleeps early if hot or battery under 15%."])
        _ = g.handle(.power(onBattery: false), now: closed.addingTimeInterval(600))
        #expect(Table.bar(g, timeZone: utc) == ["Closed 14:02 → stays awake (plugged in)", "Sleeps early if hot."])
    }
}

@Suite struct GoalTests {
    @Test func commands() {
        let never = Goal(source: .ac, kind: .neverIdleSleep)
        #expect(never.command == "sudo pmset -c sleep 0")
        #expect(never.rootShell == "/usr/bin/pmset -c sleep 0")
        #expect(Goal(source: .battery, kind: .idleSleepAfter, minutes: 10).command
            == "sudo pmset -b displaysleep 10 sleep 10")
        #expect(Goal(source: .battery, kind: .neverIdleSleep).command == "sudo pmset -b sleep 0")
        // Back to macOS's own settings (checked on macOS 27.2).
        #expect(Goal(source: .ac, kind: .macDefault).command == "sudo pmset -c displaysleep 10 sleep 1")
        #expect(Goal(source: .battery, kind: .macDefault).command == "sudo pmset -b displaysleep 2 sleep 1")
        let restored = PowerSettings(sources: [.battery: SourceSettings(["displaysleep": "2", "sleep": "1"])])
        #expect(Table.openCell(.battery, settings: restored, rule: .sleep, foreignDisableSleep: false).isDefault)
    }
}

@Suite struct SudoersTests {
    @Test func exactContents() throws {
        #expect(try Sudoers.contents(userName: "you") == """
        # Written by Clamshell. Lets you run only these commands as root, without a password.
        you ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow

        """)
    }

    @Test func refusesNamesThatNeedEscaping() {
        for bad in ["", "a b", "x,y", "ALL", "root:", "%admin", "a\nb", "1abc"] {
            #expect(throws: Sudoers.Failure.self) { try Sudoers.contents(userName: bad) }
        }
        #expect(Sudoers.isSafe(userName: "first.last"))
        #expect(Sudoers.isSafe(userName: "_clam-user1"))
    }

    @Test func installScriptCarriesExactContents() throws {
        let script = try Sudoers.installScript(userName: "you")
        let line = script.split(separator: "\n").first { $0.hasPrefix("echo ") }!
        let b64 = line.split(separator: " ")[1]
        let decoded = String(data: Data(base64Encoded: String(b64))!, encoding: .utf8)
        #expect(decoded == (try Sudoers.contents(userName: "you")))
        // Validated before it is moved into place, from a name sudo ignores.
        let visudo = script.range(of: "visudo -cf")!
        let mv = script.range(of: "/bin/mv -f")!
        #expect(visudo.lowerBound < mv.lowerBound)
        #expect(script.contains("mktemp /private/etc/sudoers.d/clamshell.XXXXXX"))
        #expect(script.hasPrefix("set -e\n"))
    }

    @Test func removeTurnsSleepBackOnFirst() {
        #expect(Sudoers.removeScript == "/usr/bin/pmset -a disablesleep 0\n/bin/rm -f /private/etc/sudoers.d/clamshell")
    }

    @Test func sudoIsNonInteractiveAndMatchesTheRule() {
        for command in Sudoers.commands {
            let args = Sudoers.sudoArguments(command)
            #expect(args.first == "-n")
            #expect(args.dropFirst().joined(separator: " ") == command)
        }
        #expect(LidGuard.Action.disableSleep(true).pmset.map(Sudoers.commands.contains) == true)
        #expect(LidGuard.Action.disableSleep(false).pmset.map(Sudoers.commands.contains) == true)
        #expect(LidGuard.Action.sleepNow.pmset.map(Sudoers.commands.contains) == true)
    }

    @Test func appleScriptQuoting() {
        #expect(Sudoers.quote("a \"b\" \\c\nd") == "\"a \\\"b\\\" \\\\c\\nd\"")
        #expect(Sudoers.appleScript(shell: "/usr/bin/pmset -c sleep 0", prompt: "Clamshell")
            == "do shell script \"/usr/bin/pmset -c sleep 0\" with prompt \"Clamshell\" with administrator privileges")
    }
}
