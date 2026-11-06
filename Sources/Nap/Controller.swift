import AppKit
import NapCore
import SwiftUI

/// Owns the lid timer, the monitors and the menu bar item.
@MainActor
final class Controller: NSObject, ObservableObject, NSMenuDelegate {
    // What the Show me window shows.
    @Published private(set) var settings = PowerSettings(sources: [:])
    @Published private(set) var rawCustom = ""
    @Published private(set) var assertions = Assertions(systemWide: [:], byProcess: [])
    @Published private(set) var guardian: LidGuard
    @Published private(set) var hasPermission = false
    @Published var message: String?

    static let durations = [15, 30, 60, 90, 120]
    static let floors = [10, 15, 20, 30]

    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var window: NSWindow?
    private lazy var lid = LidMonitor { [weak self] closed in self?.send(.lid(closed: closed)) }
    private lazy var power = PowerMonitor { [weak self] reading in self?.power(reading) }

    var minutes: Int {
        get { defaults.object(forKey: "minutes") as? Int ?? 60 }
        set { defaults.set(newValue, forKey: "minutes"); guardian.duration = TimeInterval(newValue * 60) }
    }

    var batteryFloor: Int {
        get { defaults.object(forKey: "batteryFloor") as? Int ?? 15 }
        set { defaults.set(newValue, forKey: "batteryFloor"); guardian.batteryFloor = newValue }
    }

    /// True while disablesleep 1 is set by Nap, kept across launches so a
    /// crash or forced quit is undone at the next launch.
    private var weDisabledSleep: Bool {
        get { defaults.bool(forKey: "weDisabledSleep") }
        set { defaults.set(newValue, forKey: "weDisabledSleep") }
    }

    override init() {
        let reading = PowerMonitor.read()
        guardian = LidGuard(
            duration: TimeInterval((UserDefaults.standard.object(forKey: "minutes") as? Int ?? 60) * 60),
            batteryFloor: UserDefaults.standard.object(forKey: "batteryFloor") as? Int ?? 15,
            onBattery: reading.onBattery,
            batteryPercent: reading.percent,
            thermal: ProcessInfo.processInfo.thermalState.level
        )
        super.init()
    }

    func start() {
        refresh()
        if weDisabledSleep {
            // Left on by a crash or forced quit: put sleep back.
            if settings.sleepDisabled { _ = rootRun(.disableSleep(false)) } else { weDisabledSleep = false }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()

        send(.lid(closed: lid.isClosed))
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
                if let self { self.power(PowerMonitor.read()) }
            }
        }

        // kill/Ctrl-C: restore sleep, then exit.
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
        rawCustom = Shell.pmset("-g", "custom")
        settings = PowerSettings.parse(custom: rawCustom, systemWide: Shell.pmset("-g"))
        assertions = Assertions.parse(Shell.pmset("-g", "assertions"))
        hasPermission = FileManager.default.fileExists(atPath: Sudoers.path)
    }

    // MARK: The lid timer

    private func power(_ reading: PowerMonitor.Reading) {
        send(.power(onBattery: reading.onBattery))
        if let percent = reading.percent { send(.battery(percent: percent)) }
    }

    func send(_ event: LidGuard.Event) {
        let actions = guardian.handle(event, now: Date())
        perform(actions)
        updateIcon()
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
                    // Could not turn sleep off: do not arm.
                    guardian = LidGuard(duration: guardian.duration, batteryFloor: guardian.batteryFloor,
                                        lidClosed: guardian.lidClosed, onBattery: guardian.onBattery,
                                        batteryPercent: guardian.batteryPercent, thermal: guardian.thermal)
                    timer?.cancel()
                    timer = nil
                    message = "Nap could not turn sleep off, so the lid timer is not armed. "
                        + "Use \"Allow Nap to Change Sleep\" first."
                    return
                }
            case .disableSleep(false), .sleepNow:
                _ = rootRun(action)
            }
        }
    }

    /// Runs one root action with `sudo -n`. False (and a message) on failure.
    @discardableResult
    private func rootRun(_ action: LidGuard.Action) -> Bool {
        guard let command = action.pmset else { return true }
        let result = Shell.sudo(command)
        if result.status == 0 {
            if case .disableSleep(let on) = action { weDisabledSleep = on }
            return true
        }
        NSLog("Nap: \(command) failed: \(result.output)")
        message = "\"\(command)\" failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        return false
    }

    func toggleArmed() {
        message = nil
        if guardian.isArmed {
            send(.disarm)
        } else if !hasPermission {
            allow()
            if hasPermission { send(.arm) }
        } else {
            send(.arm)
        }
        if let message { alert(message) }
    }

    func quit() {
        send(.quit)
    }

    // MARK: Root setup through the admin prompt

    func apply(_ goal: Goal) {
        message = Shell.admin(goal.rootShell, prompt: "Nap wants to run: \(goal.command)")
        refresh()
    }

    func allow() {
        let user = NSUserName()
        let contents: String
        let script: String
        do {
            contents = try Sudoers.contents(userName: user)
            script = try Sudoers.installScript(userName: user)
        } catch {
            alert("Your user name \"\(user)\" needs escaping in sudoers, so Nap will not write it.")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Allow Nap to change sleep"
        confirm.informativeText = "Nap will write this file to \(Sudoers.path), checked with visudo first. "
            + "It lets you run only these commands as root, without a password. macOS asks for your password next."
        confirm.accessoryView = Self.codeView(contents)
        confirm.addButton(withTitle: "Continue")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        if let error = Shell.admin(script, prompt: "Nap wants to add \(Sudoers.path).") {
            alert("Not installed. \(error)")
        }
        refresh()
    }

    func removePermission() {
        if guardian.isArmed { send(.disarm) }
        if let error = Shell.admin(Sudoers.removeScript, prompt: "Nap wants to remove \(Sudoers.path).") {
            alert("Not removed. \(error)")
        } else {
            weDisabledSleep = false
        }
        refresh()
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Nap"
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    static func codeView(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 460, height: 0)
        field.preferredMaxLayoutWidth = 460
        field.sizeToFit()
        field.frame.size.width = 460
        return field
    }

    // MARK: Menu bar

    private func updateIcon() {
        let (symbol, label): (String, String) = switch guardian.phase {
        case .off: ("moon.zzz", "Nap: lid timer off")
        case .armed: ("sun.max", "Nap: armed")
        case .counting: ("hourglass", "Nap: counting down")
        case .pluggedIn: ("powerplug", "Nap: lid closed, plugged in")
        case .stopped: ("moon.zzz.fill", "Nap: put the Mac to sleep")
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        statusItem?.button?.toolTip = guardian.status(now: Date())
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = menu.addItem(withTitle: guardian.status(now: Date()), action: nil, keyEquivalent: "")
        status.isEnabled = false

        let arm = item("Lid Closed: Stay Awake for \(minutes) Minutes", #selector(menuToggle))
        arm.state = guardian.isArmed ? .on : .off
        menu.addItem(arm)

        let forItem = NSMenuItem(title: "Stay Awake For", action: nil, keyEquivalent: "")
        let forMenu = NSMenu()
        for m in Self.durations {
            let i = item("\(m) Minutes", #selector(menuDuration(_:)))
            i.tag = m
            i.state = m == minutes ? .on : .off
            forMenu.addItem(i)
        }
        forItem.submenu = forMenu
        menu.addItem(forItem)

        let floorItem = NSMenuItem(title: "Sleep Early Under", action: nil, keyEquivalent: "")
        let floorMenu = NSMenu()
        for f in Self.floors {
            let i = item("\(f)% Battery", #selector(menuFloor(_:)))
            i.tag = f
            i.state = f == batteryFloor ? .on : .off
            floorMenu.addItem(i)
        }
        floorItem.submenu = floorMenu
        menu.addItem(floorItem)

        menu.addItem(.separator())
        menu.addItem(item("Show Me…", #selector(menuShow)))
        hasPermission = FileManager.default.fileExists(atPath: Sudoers.path)
        menu.addItem(hasPermission
            ? item("Remove Nap's Permission…", #selector(menuRemove))
            : item("Allow Nap to Change Sleep…", #selector(menuAllow)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Nap", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    @objc private func menuToggle() { toggleArmed() }
    @objc private func menuDuration(_ sender: NSMenuItem) { minutes = sender.tag; updateIcon() }
    @objc private func menuFloor(_ sender: NSMenuItem) { batteryFloor = sender.tag; send(.battery(percent: guardian.batteryPercent ?? 100)) }
    @objc private func menuShow() { showWindow() }
    @objc private func menuAllow() { allow() }
    @objc private func menuRemove() { removePermission() }

    /// Opens the menu, for checking it (launch with --menu).
    func openMenu() {
        statusItem?.button?.performClick(nil)
    }

    /// Writes the window as a PNG and the menu as text into `dir`, rendered
    /// by the app itself (launch with --snapshot DIR). For checking the UI
    /// where screen capture is not allowed.
    func snapshot(into dir: String) {
        showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/show-me.png"))
            }
            if let button = statusItem?.button, let w = button.window {
                NSLog("Nap: status item at \(w.frame), image \(button.image?.accessibilityDescription ?? "none")")
            }
            let menu = NSMenu()
            menuNeedsUpdate(menu)
            func lines(_ menu: NSMenu, _ indent: String) -> [String] {
                menu.items.flatMap { item -> [String] in
                    let mark = item.state == .on ? "[x] " : ""
                    let line = item.isSeparatorItem ? indent + "----" : indent + mark + item.title
                    return [line] + (item.submenu.map { lines($0, indent + "    ") } ?? [])
                }
            }
            try? (lines(menu, "").joined(separator: "\n") + "\n")
                .write(toFile: dir + "/menu.txt", atomically: true, encoding: .utf8)
        }
    }

    // MARK: Show me window

    func showWindow() {
        refresh()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ShowMe(controller: self)))
            w.title = "Nap"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 640))
            w.center()
            window = w
        }
        // A menu bar app is not active when its menu is used, and macOS 14's
        // cooperative activate() may be refused: the window then opened
        // behind every other. Take activation, and order it front anyway.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
