import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        let args = CommandLine.arguments
        if args.contains("--show") { controller.showWindow() }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            controller.snapshot(into: args[i + 1])
        }
        if args.contains("--menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.controller.openMenu() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Always put sleep back on quit when armed.
        controller.quit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
// An accessory app has no visible main menu; this one is for Cmd+Q, Cmd+W
// and text editing keys in the window.
let main = NSMenu()
let appMenu = NSMenu(title: "Nap")
appMenu.addItem(withTitle: "Quit Nap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
main.addItem(withTitle: "Nap", action: nil, keyEquivalent: "").submenu = appMenu
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
app.mainMenu = main
app.run()
