// The status item, the menu around the SwiftUI content, and the 5-second scans.

import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let store = Store()
    var hosting: NSHostingView<CacheMenu>!
    let content = NSMenuItem()
    var scanning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let screen = NSScreen.main?.visibleFrame.height ?? 900
        hosting = NSHostingView(rootView: CacheMenu(store: store, maxHeight: screen - 140))
        resizeMenu = { [weak self] in self?.sizeMenu() }
        store.reveal = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        content.view = hosting
        menu.addItem(content)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Claude Cache", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        scan()
        // .common so the bar keeps updating while the menu is open.
        RunLoop.main.add(Timer(timeInterval: scanEvery, repeats: true) { [weak self] _ in self?.scan() }, forMode: .common)
        RunLoop.main.add(Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.renderTitle() }, forMode: .common)
        sizeMenu()
        renderTitle()
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        sizeMenu()
        // The bars, rings and charts grow in. A closed menu's view doesn't update,
        // so let the open menu draw them at 0 first, then grow (a timer, because
        // an open menu only runs common-mode run-loop work; see onMain).
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            RunLoop.main.add(Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
                withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) { self?.store.reveal = 1 }
            }, forMode: .common)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        // Ready for the next open: start from nothing (or stay put under Reduce motion).
        store.reveal = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
    }

    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // macOS may want approval first: System Settings › General › Login Items.
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func sizeMenu() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard hosting.frame.size != size else { return }
        hosting.frame = NSRect(origin: .zero, size: size)
        menu.itemChanged(content)  // an open menu re-lays itself out
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", watcher, "--json"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            var result: Scan? = nil
            do {
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result = try JSONDecoder().decode(Scan.self, from: data)
            } catch {}
            onMain {
                self.scanning = false
                if let result {
                    self.store.conversations = result.conversations
                    self.store.today = result.today
                    self.store.limits = result.limits
                    self.store.dayTips = result.tips
                    self.store.error = nil
                } else {
                    self.store.error = "Couldn't read conversations (\(watcher))"
                }
                self.store.lastScan = Date()
                // Tips and rows come and go between scans: keep the menu fitted.
                onMain { self.sizeMenu() }
                self.renderTitle()
            }
        }
    }

    func renderTitle() {
        guard let latest = store.conversations.first else {
            statusItem.button?.title = "🧊 –"
            return
        }
        let left = latest.secondsLeft(at: Date())
        let state = CacheState(left: left)
        var title = left > 0 ? "\(state.emoji) \(Int(ceil(left / 60)))m" : "\(state.emoji) cold"
        // The 5-hour session's usage, when Anthropic has told us.
        if let session = store.limits?.windows?.first(where: { $0.key == "five_hour" }) {
            title += " · \(Int(session.used.rounded()))%"
        }
        statusItem.button?.title = title
        statusItem.button?.toolTip = "Claude prompt cache: \(latest.title)"
    }

    @objc func refreshNow() { scan() }
}

