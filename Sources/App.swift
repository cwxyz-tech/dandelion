// Dandelion - a free and open-source toolkit that fixes the everyday mess on your Mac.
// MIT License. See LICENSE.

import AppKit
import ServiceManagement
import SwiftUI

/// Opening Dandelion when you log in (so Time Tracker, Folder Rules and the shortcuts are always on).
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    @MainActor
    static func set(_ on: Bool, state: AppState) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                state.alertMessage = "Dandelion couldn't change its login setting: \(error.localizedDescription). You can add it yourself in System Settings → General → Login Items."
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?

    /// With something that works in the background turned on (automatic Folder Rules, Time Tracker,
    /// screenshot shortcuts, or a recording in progress), closing the window leaves Dandelion running quietly
    /// in the menu bar (no Dock icon). Otherwise it quits as usual.
    static var keepsRunning: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: "rulesAutoRun") || d.bool(forKey: "timeTracking") || d.bool(forKey: "shotsInMenuBar") || dandelionIsRecording
    }

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

    /// After turning off the last background feature from the menu bar with no window open, there's nothing left to show.
    static func quitIfIdle() {
        DispatchQueue.main.async {
            if !keepsRunning && !hasMainWindow { NSApp.terminate(nil) }
        }
    }

    static func showMainWindow(_ open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        open()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The menu bar item, shown while something runs in the background.
struct MenuBarMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject var rules: RulesModel
    @ObservedObject var tracker: TimeTrackerModel
    @ObservedObject var shots: ScreenshotModel
    @ObservedObject var recorder: RecorderModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recorder.isRecording {
            Button("Stop Recording (\(RecorderModel.format(recorder.elapsed)))") { recorder.stop() }
            Divider()
        }
        Button("Open Dandelion") { AppDelegate.showMainWindow { openWindow(id: "main") } }
        Divider()
        Section("Screenshot") {
            ForEach(ScreenshotModel.Mode.allCases) { m in
                Button("\(m.title)   \(m.shortcut.label)") { shots.capture(m, fromShortcut: true) }
            }
        }
        Section("Screen Recorder") {
            if !recorder.isRecording {
                Button("Record Screen   ⌥⇧6") {
                    if recorder.source == .window && recorder.pickedWindow == nil { recorder.source = .screen }
                    recorder.begin()
                }
            }
        }
        Section("Time Tracker") {
            Toggle(tracker.tracking ? (tracker.idle ? "Tracking (paused while away)" : "Tracking Time") : "Track Time",
                   isOn: Binding(get: { tracker.tracking }, set: { tracker.tracking = $0; AppDelegate.quitIfIdle() }))
        }
        Section("Folder Rules") {
            Toggle("Run Rules Automatically", isOn: Binding(get: { rules.autoRun }, set: { rules.autoRun = $0; AppDelegate.quitIfIdle() }))
            Button("Run Folder Rules Now") { rules.runAll(automatic: false) }
                .disabled(!rules.rules.contains { $0.enabled })
        }
        Divider()
        Toggle("Keep Screenshot Shortcuts On", isOn: Binding(get: { shots.inMenuBar }, set: { shots.inMenuBar = $0; AppDelegate.quitIfIdle() }))
        Toggle("Open at Login", isOn: Binding(get: { LoginItem.enabled }, set: { LoginItem.set($0, state: state) }))
        Button("Quit Dandelion") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@main
struct DandelionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @AppStorage("rulesAutoRun") private var rulesAutoRun = false
    @AppStorage("timeTracking") private var timeTracking = false
    @AppStorage("shotsInMenuBar") private var shotsInMenuBar = false

    var body: some Scene {
        Window("Dandelion", id: "main") {
            SuiteView()
                .environmentObject(state)
                .environmentObject(state.hover)
                .environmentObject(state.duplicates)
                .environmentObject(state.rules)
                .environmentObject(state.screenshots)
                .environmentObject(state.timeTracker)
                .environmentObject(state.recorder)
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

        MenuBarExtra(isInserted: Binding(get: { rulesAutoRun || timeTracking || shotsInMenuBar || state.recordingNow }, set: { _ in })) {
            MenuBarMenu(state: state, rules: state.rules, tracker: state.timeTracker, shots: state.screenshots, recorder: state.recorder)
        } label: {
            Image(systemName: state.recordingNow ? "record.circle.fill" : "camera.macro")
        }
    }
}
