import AppKit
import ClamshellCore
import SwiftUI

/// Owns the lid rules, the monitors and the menu bar item.
@MainActor
final class Controller: NSObject, ObservableObject {
    @Published private(set) var settings = PowerSettings(sources: [:])
    @Published private(set) var assertions = Assertions()
    @Published private(set) var guardian: LidGuard
    @Published private(set) var hasPermission = false
    @Published var message: String?

    /// --snapshot: render only. No root commands, no admin prompts, nothing
    /// written to the defaults (shared with a running Clamshell).
    let readOnly: Bool

    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private lazy var loginItem = LoginItem()
    private var timer: DispatchSourceTimer?
    private var shownLabel: String?
    private var signalSources: [DispatchSourceSignal] = []
    private var window: NSWindow?
    private lazy var lid = LidMonitor { [weak self] closed in self?.send(.lid(closed: closed)); self?.refreshIfShown() }
    private lazy var power = PowerMonitor { [weak self] reading in self?.power(reading) }

    /// True while disablesleep 1 is set by Clamshell, kept across launches so a
    /// crash or forced quit is undone at the next launch.
    private var weDisabledSleep: Bool {
        get { defaults.bool(forKey: "weDisabledSleep") }
        set { if !readOnly { defaults.set(newValue, forKey: "weDisabledSleep") } }
    }

    private static func ruleKey(_ source: PowerSource) -> String { "lidRule.\(source == .ac ? "ac" : "battery")" }

    init(readOnly: Bool) {
        self.readOnly = readOnly
        let reading = PowerMonitor.read()
        var rules: [PowerSource: LidRule] = [:]
        for source in [PowerSource.ac, .battery] {
            rules[source] = UserDefaults.standard.string(forKey: Self.ruleKey(source)).flatMap(LidRule.init(stored:)) ?? .sleep
        }
        guardian = LidGuard(rules: rules, onBattery: reading.onBattery, batteryPercent: reading.percent,
                            thermal: ProcessInfo.processInfo.thermalState.level)
        super.init()
    }

    func start() {
        refresh()
        let lidClosed = lid.isClosed
        guardian = LidGuard(rules: guardian.rules, batteryFloor: guardian.batteryFloor,
                            // Left on by a crash or forced quit: start() puts it back.
                            sleepDisabled: weDisabledSleep && settings.sleepDisabled,
                            lidClosed: lidClosed, onBattery: guardian.onBattery,
                            batteryPercent: guardian.batteryPercent, thermal: guardian.thermal)
        perform(guardian.start())  // read-only: root steps are only logged

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(item("Show Me…", #selector(menuShow)))
        menu.addItem(.separator())
        if !readOnly { menu.addItem(loginItem.menuItem) }
        menu.addItem(item("Uninstall Clamshell…", #selector(uninstall)))
        menu.addItem(item("Quit Clamshell", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        status.menu = menu
        statusItem = status
        updateIcon()

        lid.start()
        power.start()
        let center = NotificationCenter.default
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.thermal(ProcessInfo.processInfo.thermalState.level)) }
        }
        // Second sources for the lid: the built-in screen goes away when it
        // closes, and the state may have changed while asleep.
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lid.changed() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lid.changed()
                self?.power(PowerMonitor.read())
            }
        }

        // kill/Ctrl-C: put sleep back, then exit.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.quit() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Reading the settings

    func refresh() {
        settings = PowerSettings.parse(custom: Shell.pmset("-g", "custom"), systemWide: Shell.pmset("-g"))
        assertions = Assertions.parse(Shell.pmset("-g", "assertions"))
        hasPermission = FileManager.default.fileExists(atPath: Sudoers.path)
    }

    private func refreshIfShown() {
        if window?.isVisible == true { refresh() }
    }

    /// `disablesleep 1` is set, and not by Clamshell.
    var foreignDisableSleep: Bool { settings.sleepDisabled && !guardian.sleepDisabled }

    // MARK: Lid rules

    private func power(_ reading: PowerMonitor.Reading) {
        send(.power(onBattery: reading.onBattery))
        if let percent = reading.percent { send(.battery(percent: percent)) }
        refreshIfShown()
    }

    func send(_ event: LidGuard.Event) {
        perform(guardian.handle(event, now: Date()))
        updateIcon()
    }

    func setRule(_ rule: LidRule, for source: PowerSource) {
        message = nil
        send(.setRule(source, rule))
        if !readOnly, guardian.rule(source) == rule {
            defaults.set(rule.stored, forKey: Self.ruleKey(source))
        }
        refresh()
    }

    private func perform(_ actions: [LidGuard.Action]) {
        for action in actions {
            switch action {
            case .startTimer(let seconds):
                timer?.cancel()
                let t = DispatchSource.makeTimerSource(queue: .main)
                t.schedule(wallDeadline: .now() + seconds)
                t.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.send(.timerFired) }
                }
                t.resume()
                timer = t
            case .cancelTimer:
                timer?.cancel()
                timer = nil
            case .disableSleep(true):
                if !rootRun(action) {
                    // Sleep could not be held off: drop this source's stay-awake rule.
                    let source = guardian.source
                    var rules = guardian.rules
                    rules[source] = .sleep
                    if !readOnly { defaults.set(LidRule.sleep.stored, forKey: Self.ruleKey(source)) }
                    guardian = LidGuard(rules: rules, batteryFloor: guardian.batteryFloor,
                                        lidClosed: guardian.lidClosed, onBattery: guardian.onBattery,
                                        batteryPercent: guardian.batteryPercent, thermal: guardian.thermal)
                    timer?.cancel()
                    timer = nil
                    message = "Clamshell could not turn sleep off, so the lid closed \(source.label.lowercased()) rule "
                        + "is back to sleep at once. \(message ?? "")"
                    return
                }
            case .disableSleep(false), .sleepNow:
                rootRun(action)
            }
        }
    }

    /// Runs one root action with `sudo -n`. False (and a message) on failure.
    @discardableResult
    private func rootRun(_ action: LidGuard.Action) -> Bool {
        guard let command = action.pmset else { return true }
        if readOnly {
            NSLog("Clamshell (read-only): would run sudo -n \(command)")
            return true
        }
        let result = Shell.sudo(command)
        if result.status == 0 {
            if case .disableSleep(let on) = action { weDisabledSleep = on }
            return true
        }
        NSLog("Clamshell: \(command) failed: \(result.output)")
        message = "\"sudo -n \(command)\" failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        return false
    }

    func quit() {
        send(.quit)
    }

    // MARK: Admin prompt

    func apply(_ goal: Goal) {
        guard !readOnly else { return }
        message = Shell.admin(goal.rootShell, prompt: "Clamshell wants to run: \(goal.command)")
        refresh()
    }

    var sudoersContents: String { (try? Sudoers.contents(userName: NSUserName())) ?? "" }

    /// The one-time permission, shown inline in a lid-closed cell. The cell
    /// shows the exact file first; this runs the admin prompt.
    func allow() {
        guard !readOnly else { return }
        guard let script = try? Sudoers.installScript(userName: NSUserName()) else {
            message = "Your user name \"\(NSUserName())\" needs escaping in sudoers, so Clamshell will not write it."
            return
        }
        message = Shell.admin(script, prompt: "Clamshell wants to add \(Sudoers.path).").map { "Not installed. \($0)" }
        refresh()
    }

    /// Deleting an app runs nothing, so Clamshell's permission would outlive it.
    /// This takes it back (sleep on, the sudoers file gone, no login item), then quits, so
    /// the app can go to the Trash with nothing left behind.
    @objc func uninstall() {
        guard !readOnly else { return }
        if FileManager.default.fileExists(atPath: Sudoers.path) {
            if let error = Shell.admin(Sudoers.removeScript, prompt: "Clamshell wants to remove \(Sudoers.path).") {
                message = "Not removed. \(error)"
                showWindow()
                return
            }
        }
        loginItem.remove()
        NSApp.terminate(nil)
    }

    // MARK: Menu bar

    private func updateIcon() {
        let (filled, label): (Bool, String) = switch guardian.phase {
        case .idle where guardian.sleepDisabled: (true, "Clamshell: lid closed stays awake")
        case .idle: (false, "Clamshell")
        case .awake(_, nil): (true, "Clamshell: lid closed, staying awake")
        case .awake: (true, "Clamshell: lid closed, counting down")
        case .stopped: (false, "Clamshell: put the Mac to sleep")
        }
        // No tooltip: Clamshell never comes to the front, and its hover label sometimes
        // stayed on screen after the pointer left. The label still reaches VoiceOver.
        guard label != shownLabel else { return }
        shownLabel = label
        statusItem?.button?.image = ClamGlyph.image(filled: filled, label: label)
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    @objc private func menuShow() { showWindow() }

    // MARK: Show me window

    func showWindow() {
        refresh()
        if window == nil {
            let host = NSHostingController(rootView: ShowMe(controller: self,
                snapshotCell: readOnly ? .init(source: .battery, lidClosed: true) : nil))
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.title = "Clamshell"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            window = w
        }
        if let view = window?.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            window?.setContentSize(view.fittingSize)
        }
        // A menu bar app is not active when its menu is used, and macOS 14's
        // cooperative activate() may be refused: the window then opened
        // behind every other. Take activation, and order it front anyway.
        // A snapshot renders off-screen and never takes the user's focus.
        if readOnly {
            window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window?.orderBack(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Renders the window, and the choices of one lid-closed cell, as PNGs in
    /// `dir` (launch with --snapshot DIR), for checking where screen capture
    /// is not allowed.
    func snapshot(into dir: String) {
        // Any popover this opens stays transparent, from its first update.
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: nil) { note in
            guard let w = note.object as? NSWindow, String(describing: type(of: w)).contains("Popover") else { return }
            MainActor.assumeIsolated { w.alphaValue = 0 }
        }
        showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            if let view = window?.contentView { Self.png(view, to: dir + "/show-me.png") }
            for (name, closed, details) in [("show-me-cell.png", true, false),
                                            ("show-me-cell-open.png", false, false)] {
                let choices = NSHostingView(rootView: CellChoices(controller: self, source: .battery, lidClosed: closed,
                                                                  initial: closed ? .stayAwake(minutes: 60) : nil,
                                                                  showDetails: details)
                    .frame(width: 360).padding(14).background(Color(nsColor: .windowBackgroundColor)))
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: choices.fittingSize), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
                w.contentView = choices
                choices.layoutSubtreeIfNeeded()
                Self.png(choices, to: dir + "/" + name)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in popoverSnapshot(into: dir) }
            if let button = statusItem?.button, let bw = button.window {
                NSLog("Clamshell: status item at \(bw.frame)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { NSApp.terminate(nil) }
        }
    }

    /// The popover SwiftUI opened on the lid-closed battery cell (ShowMe's
    /// snapshotCell) after Stay awake and Details are clicked, and the Details
    /// popover beside it, as the user sees them. Kept invisible.
    private func popoverSnapshot(into dir: String) {
        let pops = NSApp.windows.filter { $0 !== window && String(describing: type(of: $0)).contains("Popover") }
        for (i, p) in pops.enumerated() {
            p.alphaValue = 0
            guard let v = p.contentView else { continue }
            NSLog("Clamshell: popover window \(p.frame), content \(v.frame.size), wants \(v.fittingSize)")
            Self.png(v, to: dir + "/show-me-popover-\(i).png")
        }
        if pops.isEmpty { NSLog("Clamshell: no popover window") }
    }

    private static func png(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
