import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller(readOnly: CommandLine.arguments.contains("--snapshot"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        let args = CommandLine.arguments
        if args.contains("--show") { controller.showWindow() }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            controller.snapshot(into: args[i + 1])
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Put sleep back if Clamshell holds it off.
        controller.quit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening Clamshell again (from Finder, Spotlight or `open`) shows the window,
    /// so it can be reached when a full menu bar hides the icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showWindow()
        return false
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
// An accessory app has no visible main menu; this one is for Cmd+Q, Cmd+W
// and text editing keys in the window.
let main = NSMenu()
let appMenu = NSMenu(title: "Clamshell")
appMenu.addItem(withTitle: "Quit Clamshell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
main.addItem(withTitle: "Clamshell", action: nil, keyEquivalent: "").submenu = appMenu
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
app.mainMenu = main
app.run()
