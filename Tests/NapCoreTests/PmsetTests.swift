import Testing
import Foundation
@testable import NapCore

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

@Suite struct ExplainTests {
    @Test func explainsThisMacHonestly() {
        let settings = PowerSettings.parse(custom: Fixture.text("pmset-custom"), systemWide: Fixture.text("pmset-g"))
        #expect(Explain.sentences(settings) == [
            "Plugged in and on battery: the Mac sleeps after 1 minute idle, but never while the display is on "
                + "(the display never turns off), so in practice it never idle-sleeps with the lid open.",
            "Lid closed: sleeps at once (unless an external display is connected).",
        ])
    }

    @Test func splitsSourcesThatDiffer() {
        let settings = PowerSettings(sources: [
            .ac: SourceSettings(["sleep": "0", "displaysleep": "10"]),
            .battery: SourceSettings(["sleep": "5", "displaysleep": "5"]),
        ])
        #expect(Explain.sentences(settings).prefix(2) == [
            "Plugged in: the display turns off after 10 minutes idle. The Mac never sleeps when idle.",
            "On battery: the display turns off after 5 minutes idle, and the Mac sleeps right after.",
        ])
    }

    @Test func idleCases() {
        #expect(Explain.idle(SourceSettings(["sleep": "0", "displaysleep": "0"])) == "never sleeps when idle, and the display never turns off.")
        #expect(Explain.idle(SourceSettings(["sleep": "30", "displaysleep": "10"])) == "the display turns off after 10 minutes idle, and the Mac sleeps after 30 minutes idle.")
    }

    @Test func sleepDisabledSaysSo() {
        let settings = PowerSettings(sources: [.ac: SourceSettings(["sleep": "1"])], sleepDisabled: true)
        #expect(Explain.sentences(settings).count == 1)
        #expect(Explain.sentences(settings)[0].hasPrefix("Sleep is turned off"))
    }

    @Test func awakeLinesFromThisMac() {
        let a = Assertions.parse(Fixture.text("pmset-assertions"))
        #expect(Explain.awake(a) == [
            "The display is on (macOS never idle-sleeps while it is).",
            "runningboardd (pid 611): for com.apple.dataaccess.dataaccessd",
            "sharingd (pid 964): Handoff",
            "caffeinate (pid 28339): caffeinate command-line tool, for 94 s more",
        ])
    }
}

@Suite struct GoalTests {
    @Test func commands() {
        let all = Goal.all
        #expect(all.map(\.command) == [
            "sudo pmset -c sleep 0",
            "sudo pmset -c displaysleep 30 sleep 30",
            "sudo pmset -b sleep 0",
            "sudo pmset -b displaysleep 10 sleep 10",
        ])
        #expect(all[0].rootShell == "/usr/bin/pmset -c sleep 0")
        #expect(all[0].title == "Plugged in: never sleep when idle")
        #expect(all[3].title == "On battery: sleep after 10 minutes idle")
    }

    @Test func isMetReadsCurrentSettings() {
        let settings = PowerSettings.parse(custom: Fixture.text("pmset-custom"))
        #expect(Goal.all.allSatisfy { !$0.isMet(by: settings) })
        var g = Goal(source: .battery, kind: .idleSleepAfter, minutes: 1)
        #expect(!g.isMet(by: settings))  // displaysleep is 0, not 1
        g = Goal(source: .ac, kind: .neverIdleSleep)
        let never = PowerSettings(sources: [.ac: SourceSettings(["sleep": "0", "displaysleep": "0"])])
        #expect(g.isMet(by: never))
    }
}

@Suite struct SudoersTests {
    @Test func exactContents() throws {
        #expect(try Sudoers.contents(userName: "you") == """
        # Written by Nap. Lets you run only these commands as root, without a password.
        you ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow

        """)
    }

    @Test func refusesNamesThatNeedEscaping() {
        for bad in ["", "a b", "x,y", "ALL", "root:", "%admin", "a\nb", "1abc"] {
            #expect(throws: Sudoers.Failure.self) { try Sudoers.contents(userName: bad) }
        }
        #expect(Sudoers.isSafe(userName: "first.last"))
        #expect(Sudoers.isSafe(userName: "_nap-user1"))
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
        #expect(script.contains("mktemp /private/etc/sudoers.d/nap.XXXXXX"))
        #expect(script.hasPrefix("set -e\n"))
    }

    @Test func removeTurnsSleepBackOnFirst() {
        #expect(Sudoers.removeScript == "/usr/bin/pmset -a disablesleep 0\n/bin/rm -f /private/etc/sudoers.d/nap")
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
        #expect(Sudoers.appleScript(shell: "/usr/bin/pmset -c sleep 0", prompt: "Nap")
            == "do shell script \"/usr/bin/pmset -c sleep 0\" with prompt \"Nap\" with administrator privileges")
    }
}
