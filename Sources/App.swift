// Dandelion - a free and open-source disk space visualizer for macOS.
// MIT License. See LICENSE.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DandelionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Dandelion", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan a Folder…") { state.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { state.rescan() }
                    .keyboardShortcut("r")
                    .disabled(!state.canRescan)
                Divider()
                Button("Show Disks") { state.goHome() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}
