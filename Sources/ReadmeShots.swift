// Dandelion - makes the screenshots in the README. Only runs when asked from the command line:
//     Dandelion.app/Contents/MacOS/Dandelion --snapshot out.png --scan /Applications [--dark]
//     Dandelion.app/Contents/MacOS/Dandelion --snapshot out.png --tool timeTracker   (made-up sample day)
// It scans the folder (or opens the tool), waits for it to settle, saves a picture of its own window and quits.
// It never touches anything on disk except writing that one picture.
// MIT License. See LICENSE.

import AppKit
import Foundation

@MainActor
enum ReadmeShots {
    static func startIfAsked(_ state: AppState) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let out = value("--snapshot") else { return }
        NSApp.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        if let name = value("--tool"), let tool = Tool(rawValue: name) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if let w = mainWindow { w.setContentSize(NSSize(width: 1260, height: 800)); w.center() }
                state.tool = tool
                if tool == .timeTracker { state.timeTracker.showSample() }
                try? await Task.sleep(for: .seconds(3))
                save(to: out)
                exit(0)
            }
            return
        }
        guard let folder = value("--scan") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if let w = mainWindow { w.setContentSize(NSSize(width: 1260, height: 800)); w.center() }
            state.scanFolder(folder)
            while state.phase != .results { try? await Task.sleep(for: .milliseconds(200)) }
            state.hasFullDiskAccess = true   // the build machine has no Full Disk Access; hide that banner
            try? await Task.sleep(for: .seconds(4))   // let the chart finish sweeping in
            save(to: out)
            exit(0)
        }
    }

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.canBecomeMain } }

    private static func save(to path: String) {
        guard let win = mainWindow, let view = win.contentView?.superview ?? win.contentView else {
            FileHandle.standardError.write("snapshot: no window\n".data(using: .utf8)!); exit(1)
        }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        rep.size = size   // twice the pixels: sharp on Retina screens
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch {
            FileHandle.standardError.write("snapshot: \(error)\n".data(using: .utf8)!); exit(1)
        }
    }
}
