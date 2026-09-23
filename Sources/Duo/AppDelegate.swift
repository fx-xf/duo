import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var engine: BendEngine!
    private var shelf: WidgetShelf!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var escMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = BendEngine()
        shelf = WidgetShelf()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macbook", accessibilityDescription: "Duo")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Esc pauses while the desktop is bent. Only reaches us if the user has
        // granted Accessibility; the menu bar item always works.
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.engine.progress > 0.01 else { return }
            Preferences.shared.paused = true
        }

        if !DesktopCapture.hasPermission {
            DesktopCapture.requestPermission()
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
    }

    /// Rebuilt on every open so the status line is never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let prefs = Preferences.shared
        menu.removeAllItems()

        let permitted = DesktopCapture.hasPermission
        let statusText: String
        if !permitted {
            statusText = "Needs Screen Recording"
        } else if prefs.paused {
            statusText = "Paused"
        } else if prefs.followLid {
            statusText = "Following the lid · \(Int(engine.rawAngle))°"
        } else {
            statusText = "Manual angle · \(Int(prefs.manualAngle))°"
        }
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if !permitted {
            let allow = NSMenuItem(title: "Allow Screen Recording…", action: #selector(openPermission), keyEquivalent: "")
            allow.target = self
            menu.addItem(allow)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: prefs.paused ? "Resume" : "Pause",
                                action: #selector(togglePause), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for style in BendStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = prefs.style == style ? .on : .off
            styleMenu.addItem(item)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem(title: "Quit Duo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openPermission() {
        DesktopCapture.requestPermission()
        DesktopCapture.openPermissionSettings()
    }

    @objc private func togglePause() {
        Preferences.shared.paused.toggle()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = BendStyle(rawValue: raw) else { return }
        Preferences.shared.style = style
    }

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "Duo"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(engine: engine, shelf: shelf))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
