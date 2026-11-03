// Dandelion - a free and open-source toolkit that fixes the everyday mess on your Mac.
// MIT License. See LICENSE.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?

    /// With Folder Rules set to run automatically, closing the window leaves Dandelion running quietly
    /// in the menu bar (no Dock icon) so rules keep working, like Hazel. Otherwise it quits as usual.
    static var keepsRunning: Bool { UserDefaults.standard.bool(forKey: "rulesAutoRun") }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Self.keepsRunning }
    // saved window state is only ever restored with secure coding
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.canBecomeMain else { return }
            // hide the Dock icon once the main window is gone, if Dandelion is staying open for Folder Rules
            DispatchQueue.main.async {
                let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
                if Self.keepsRunning && !others { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    // opening Dandelion again (Finder, Spotlight) while it's only in the menu bar brings the window back
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }

    static var hasMainWindow: Bool { NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } }

    static func showMainWindow(_ open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        open()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The menu bar item shown while Folder Rules run automatically.
struct MenuBarMenu: View {
    @ObservedObject var rules: RulesModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(rules.rules.contains { $0.enabled } ? "Folder Rules are running" : "No Folder Rules turned on")
        Divider()
        Button("Open Dandelion") { AppDelegate.showMainWindow { openWindow(id: "main") } }
        Button("Run Folder Rules Now") { rules.runAll(automatic: false) }
            .disabled(!rules.rules.contains { $0.enabled })
        Button("Stop Running Rules Automatically") {
            rules.autoRun = false
            if !AppDelegate.hasMainWindow { NSApp.terminate(nil) }   // nothing left on screen to keep it open for
        }
        Divider()
        Button("Quit Dandelion") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@main
struct DandelionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @AppStorage("rulesAutoRun") private var rulesAutoRun = false

    var body: some Scene {
        Window("Dandelion", id: "main") {
            SuiteView()
                .environmentObject(state)
                .environmentObject(state.hover)
                .environmentObject(state.duplicates)
                .environmentObject(state.rules)
                .frame(minWidth: 1020, minHeight: 660)
        }
        .defaultSize(width: 1260, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan a Folder…") { state.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { state.rescan() }
                    .keyboardShortcut("r")
                    .disabled(!state.canRescan)
                Divider()
                Button("Show Disks") { state.tool = .diskMap; state.goHome() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("Tools") {
                ForEach(Array(Tool.shipped.enumerated()), id: \.element) { i, t in
                    Button(t.title) { state.tool = t }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Dandelion") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Dandelion",
                        .applicationVersion: state.appVersion,
                        .credits: NSAttributedString(string: "\(Brand.catchphrase)\nFree and open source under the MIT License.\ncoleswebsite.xyz/dandelion"),
                    ])
                }
            }
        }

        MenuBarExtra("Dandelion", systemImage: "camera.macro", isInserted: Binding(get: { rulesAutoRun }, set: { _ in })) {
            MenuBarMenu(rules: state.rules)
        }
    }
}
