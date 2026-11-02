// Dandelion - a free and open-source disk space visualizer for macOS.
// MIT License. See LICENSE.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    // saved window state is only ever restored with secure coding
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

@main
struct DandelionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

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
                ForEach(Array(Tool.allCases.enumerated()), id: \.element) { i, t in
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
    }
}
