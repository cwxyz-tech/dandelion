// Dandelion - makes the screenshots in the README, on the build machine. It only runs when the environment
// variable DANDELION_README_SHOTS=1 is set AND it's asked from the command line, so it never runs for you:
//     Dandelion --snapshot out.png --scan /Applications [--dark]
//     Dandelion --snapshot out.png --tool timeTracker          (a made-up sample day, never saved)
//     Dandelion --snapshot out.png --editor                    (the markup editor on a sample picture)
//     Dandelion --snapshot out.png --export-preview            (the recorder's styled preview of a sample clip)
// It saves a picture of its own window and quits. Sample files go in a temporary folder.
// MIT License. See LICENSE.

import AppKit
import AVFoundation
import CoreMedia
import Foundation

@MainActor
enum ReadmeShots {
    static func startIfAsked(_ state: AppState) {
        guard ProcessInfo.processInfo.environment["DANDELION_README_SHOTS"] == "1" else { return }
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let out = value("--snapshot") else { return }
        NSApp.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            prepareWindow()

            if let name = value("--tool"), let tool = Tool(rawValue: name) {
                state.tool = tool
                if tool == .timeTracker { state.timeTracker.showSample() }
                try? await Task.sleep(for: .seconds(3))
                save(mainWindow, to: out)
            } else if args.contains("--editor") {
                guard let picture = await samplePicture(state) else { fail("no sample picture") }
                state.tool = .screenshot
                guard let editor = state.screenshots.openEditor(picture) else { fail("editor didn't open") }
                editor.saved = true
                drawSampleMarks(editor)
                try? await Task.sleep(for: .seconds(2))
                save(editor.window, to: out)
            } else if args.contains("--export-preview") {
                guard let picture = await samplePicture(state), let item = await sampleRecording(from: picture) else { fail("no sample clip") }
                state.tool = .recorder
                state.recorder.style.background = 1
                state.recorder.edit(item)
                for _ in 0..<50 where state.recorder.preview == nil { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1))
                save(mainWindow, to: out)
            } else if let folder = value("--scan") {
                await scan(state, folder)
                save(mainWindow, to: out)
            }
            exit(0)
        }
    }

    /// The main window, remembered before any other window (like the markup editor) opens.
    private static var mainWindow: NSWindow?

    /// Same size every time, and frontmost, so the colors look the way they do when you're using it.
    private static func prepareWindow() {
        mainWindow = NSApp.windows.first { $0.canBecomeMain }
        guard let w = mainWindow else { return }
        w.setContentSize(NSSize(width: 1260, height: 800))
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private static func scan(_ state: AppState, _ folder: String) async {
        state.tool = .diskMap
        state.scanFolder(folder)
        while state.phase != .results { try? await Task.sleep(for: .milliseconds(200)) }
        state.hasFullDiskAccess = true   // the build machine has no Full Disk Access; hide that banner
        try? await Task.sleep(for: .seconds(4))   // let the chart finish sweeping in
    }

    private static var sampleFolder: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dandelion-readme", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A picture of Dandelion's own Disk Map, to mark up and to "record".
    private static func samplePicture(_ state: AppState) async -> URL? {
        await scan(state, "/Applications")
        guard let cg = image(of: mainWindow) else { return nil }
        let url = sampleFolder.appendingPathComponent("Screenshot sample.png")
        guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: url)
        return url
    }

    /// Marks drawn the same way you would: through the editor's own drawing steps.
    private static func drawSampleMarks(_ e: ShotEditor) {
        let w = e.pixelSize.width, h = e.pixelSize.height
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: w * x, y: h * y) }
        func drag(_ kind: MarkKind, _ color: Int, _ a: CGPoint, _ b: CGPoint) {
            e.tool = kind
            e.color = color
            e.begin(at: a)
            e.move(to: b)
            e.end()
        }
        drag(.blur, 0, p(0.19, 0.53), p(0.48, 0.7))
        drag(.box, 0, p(0.505, 0.15), p(0.97, 0.93))
        drag(.highlight, 2, p(0.19, 0.205), p(0.48, 0.25))
        drag(.arrow, 0, p(0.3, 0.74), p(0.3, 0.27))
        e.tool = .text
        e.color = 4
        e.begin(at: p(0.2, 0.75))
        e.textEntry = "Clear these out"
        e.commitText()
        e.tool = .arrow
        e.color = 0
    }

    /// A short clip made from the sample picture, with a pointer that glides over and clicks.
    private static func sampleRecording(from picture: URL) async -> RecordingItem? {
        guard let src = CGImageSourceCreateWithURL(picture as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = full.width / 2 / 2 * 2, h = full.height / 2 / 2 * 2
        let raw = sampleFolder.appendingPathComponent("Recording sample.mov")
        try? FileManager.default.removeItem(at: raw)
        guard let writer = try? AVAssetWriter(outputURL: raw, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        let seconds = 4, fps = 10
        for f in 0..<(seconds * fps) {
            var pb: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        // the pointer drifts from the list toward the chart and clicks a slice
        let cursor = (0...80).map { i -> CursorSample in
            let t = Double(i) * 0.05, k = min(1, t / 1.6)
            let e = k * k * (3 - 2 * k)
            return CursorSample(t: t, x: 0.3 + (0.72 - 0.3) * e, y: 0.4 + (0.36 - 0.4) * e)
        }
        let info = RecordingInfo(duration: Double(seconds), width: w, height: h, cursor: cursor,
                                 clicks: [ClickEvent(t: 1.7, x: 0.72, y: 0.36)], hasAudio: false, created: Date())
        return RecordingItem(raw: raw, info: info)
    }

    private static func image(of win: NSWindow?) -> CGImage? {
        guard let win, let view = win.contentView?.superview ?? win.contentView else { return nil }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size   // twice the pixels: sharp on Retina screens
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func save(_ win: NSWindow?, to path: String) {
        guard let cg = image(of: win), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            fail("no window to save")
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { fail("\(error)") }
    }

    private static func fail(_ why: String) -> Never {
        FileHandle.standardError.write("snapshot: \(why)\n".data(using: .utf8)!)
        exit(1)
    }
}
