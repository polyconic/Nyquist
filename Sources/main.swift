import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MainWindowController?
    /// Set when Finder hands us a file before the window exists.
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let c = controller ?? MainWindowController()
        controller = c
        buildMenu(for: c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let url = pendingURL {
            pendingURL = nil
            c.open(url: url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        guard let c = controller else { pendingURL = url; return }
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.open(url: url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        application(sender, open: [URL(fileURLWithPath: filename)])
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu(for controller: MainWindowController) {
        let main = NSMenu()

        // Explicit targets: relying on the responder chain leaves these items dead.
        func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                 _ key: String, _ mask: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = controller
        }

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AppInfo.name)", action: #selector(about), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        add(fileMenu, "Open…", #selector(MainWindowController.openDocument(_:)), "o")
        let recentItem = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        // Private hook that makes AppKit populate the recents list. Guarded: if a future
        // macOS drops it, the menu is simply empty instead of crashing at launch.
        let setMenuName = Selector(("_setMenuName:"))
        if recentMenu.responds(to: setMenuName) {
            recentMenu.perform(setMenuName, with: "NSRecentDocumentsMenu")
        }
        recentItem.submenu = recentMenu
        fileMenu.addItem(.separator())
        add(fileMenu, "Export Image…", #selector(MainWindowController.exportImage), "e")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        add(viewMenu, "Zoom In", #selector(MainWindowController.zoomIn), "+")
        add(viewMenu, "Zoom Out", #selector(MainWindowController.zoomOut), "-")
        add(viewMenu, "Fit to Window", #selector(MainWindowController.resetZoom), "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func about() {
        let ffmpeg = AudioLoader.ffmpegPath()
        let credits = NSMutableAttributedString(string: """
            High-resolution audio spectrum analyser.

            Analysis runs on Accelerate/vDSP. Decoding uses AVFoundation, \
            which covers WAV, AIFF, FLAC, MP3, AAC/M4A, ALAC, Ogg, CAF and Wave64.
            ffmpeg: \(ffmpeg ?? "not installed — optional, adds Opus, WavPack and others")

            Scroll to zoom time · Shift-scroll to zoom frequency · Drag to pan · 0 to fit
            """, attributes: [.font: NSFont.systemFont(ofSize: 11)])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .credits: credits,
        ])
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
