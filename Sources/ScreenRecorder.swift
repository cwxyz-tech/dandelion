// Dandelion - Screen Recorder capture: records the screen, a window or an area with ScreenCaptureKit,
// plus the microphone if you want it, and notes where the cursor goes and where you click.
// The system cursor is left out of the video; Dandelion draws a smooth, bigger one when exporting.
// MIT License. See LICENSE.

import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import ScreenCaptureKit

/// Set while a recording is running (read when deciding whether closing the window should quit).
nonisolated(unsafe) var dandelionIsRecording = false

/// Writes ScreenCaptureKit frames (and microphone audio) into a movie file. Callbacks arrive on one serial queue.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let url: URL
    let pixelSize: CGSize
    private let filter: SCContentFilter
    private let sourceRect: CGRect?
    private let wantsMic: Bool
    private let queue = DispatchQueue(label: "dandelion.recorder")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var mic: AVCaptureSession?
    private var started = false
    private var firstTime = CMTime.invalid
    private var lastTime = CMTime.invalid
    /// Host-clock seconds of the first frame, so cursor samples can be lined up with the video.
    private(set) var startHostSeconds: Double = 0
    var onFirstFrame: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    init(url: URL, filter: SCContentFilter, sourceRect: CGRect?, pixelSize: CGSize, mic: Bool) {
        self.url = url
        self.filter = filter
        self.sourceRect = sourceRect
        self.wantsMic = mic
        // the encoder wants even sizes
        self.pixelSize = CGSize(width: max(2, floor(pixelSize.width / 2) * 2), height: max(2, floor(pixelSize.height / 2) * 2))
    }

    func start() async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, w * h * 8),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError.message("The video couldn't be set up.") }
        writer.add(video)
        self.writer = writer
        self.videoInput = video

        if wantsMic, let device = AVCaptureDevice.default(for: .audio) {
            let session = AVCaptureSession()
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVNumberOfChannelsKey: 1,
                        AVSampleRateKey: 48_000,
                        AVEncoderBitRateKey: 128_000,
                    ])
                    audio.expectsMediaDataInRealTime = true
                    if writer.canAdd(audio) {
                        writer.add(audio)
                        audioInput = audio
                        mic = session
                    }
                }
            }
        }

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.colorSpaceName = CGColorSpace.sRGB
        if let r = sourceRect { config.sourceRect = r }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        mic?.startRunning()
        try await stream.startCapture()
    }

    /// Stops and finishes the file. Returns the length in seconds.
    func stop() async -> Double {
        try? await stream?.stopCapture()
        mic?.stopRunning()
        return await withCheckedContinuation { (cont: CheckedContinuation<Double, Never>) in
            queue.async {
                guard let writer = self.writer, self.started else {
                    self.writer?.cancelWriting()
                    cont.resume(returning: 0)
                    return
                }
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let end = CMTimeMaximum(self.lastTime, now)
                writer.endSession(atSourceTime: CMTimeSubtract(end, self.firstTime))
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                let length = CMTimeGetSeconds(CMTimeSubtract(end, self.firstTime))
                writer.finishWriting {
                    cont.resume(returning: writer.status == .completed ? length : 0)
                }
            }
        }
    }

    var hasAudio: Bool { audioInput != nil }

    // MARK: ScreenCaptureKit

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let writer, let videoInput else { return }
        // skip frames where nothing changed (the movie simply holds the last picture)
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started {
            guard writer.startWriting() else {
                onError?(writer.error?.localizedDescription ?? "The recording couldn't start.")
                return
            }
            writer.startSession(atSourceTime: .zero)   // the file's clock starts at the first frame
            started = true
            firstTime = pts
            startHostSeconds = CMTimeGetSeconds(pts)
            onFirstFrame?(startHostSeconds)
        }
        lastTime = pts
        if videoInput.isReadyForMoreMediaData, let b = Self.retimed(sampleBuffer, by: firstTime) { videoInput.append(b) }
    }

    /// A copy of the buffer with its times moved back by `offset`.
    static func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in infos.indices {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            if infos[i].decodeTimeStamp.isValid { infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &infos, sampleBufferOut: &out)
        return out
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }

    // MARK: microphone

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard started, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(pts, firstTime) >= 0, let b = Self.retimed(sampleBuffer, by: firstTime) else { return }
        audioInput.append(b)
    }
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// Follows the mouse while recording: where the pointer is (60 times a second) and every click.
/// Positions are stored as fractions of the recorded area, in the area's own top-left coordinates.
@MainActor
final class PointerTracker {
    /// The recorded area in global screen points, top-left origin (the coordinates ScreenCaptureKit uses).
    let region: CGRect
    private(set) var samples: [CursorSample] = []
    private(set) var clicks: [ClickEvent] = []
    private var timer: Timer?
    private var monitors: [Any] = []
    private var startHost: Double?

    init(region: CGRect) {
        self.region = region
    }

    func start() {
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.sample() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        let handler: (NSEvent) -> Void = { _ in
            MainActor.assumeIsolated { self.click() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            monitors.append(l)
        }
    }

    /// Lines the timeline up with the first video frame.
    func setStart(hostSeconds: Double) {
        let shift = (startHost ?? hostSeconds) - hostSeconds
        startHost = hostSeconds
        // samples taken before the first frame keep their (negative) place in time
        samples = samples.map { CursorSample(t: $0.t + shift, x: $0.x, y: $0.y) }
        clicks = clicks.map { ClickEvent(t: $0.t + shift, x: $0.x, y: $0.y) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    private func now() -> Double {
        let host = CACurrentMediaTime()
        if startHost == nil { startHost = host }
        return host - (startHost ?? host)
    }

    private func position() -> (Double, Double) {
        let loc = NSEvent.mouseLocation   // bottom-left origin
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let gx = loc.x, gy = mainHeight - loc.y
        return ((gx - region.minX) / max(region.width, 1), (gy - region.minY) / max(region.height, 1))
    }

    private func sample() {
        let (x, y) = position()
        let t = now()
        if let last = samples.last, abs(last.x - x) < 0.0001, abs(last.y - y) < 0.0001, t - last.t < 0.5 { return }
        samples.append(CursorSample(t: t, x: x, y: y))
    }

    private func click() {
        let (x, y) = position()
        guard x >= -0.02, x <= 1.02, y >= -0.02, y <= 1.02 else { return }   // clicks outside the recording don't zoom
        clicks.append(ClickEvent(t: now(), x: x, y: y))
    }
}

/// A full-screen overlay for dragging out the area to record. Esc cancels.
@MainActor
enum AreaPicker {
    private static var window: NSWindow?
    private static var continuation: CheckedContinuation<(NSScreen, CGRect)?, Never>?

    /// Returns the screen and the chosen rectangle in that screen's own points (top-left origin), or nil.
    static func pick() async -> (NSScreen, CGRect)? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return nil }
        return await withCheckedContinuation { cont in
            continuation = cont
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = AreaPickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDone = { rect in
                MainActor.assumeIsolated {
                    finish(rect.map { r in (screen, CGRect(x: r.minX, y: screen.frame.height - r.maxY, width: r.width, height: r.height)) })
                }
            }
            w.contentView = view
            window = w
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(view)
        }
    }

    private static func finish(_ result: (NSScreen, CGRect)?) {
        window?.orderOut(nil)
        window = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class AreaPickerView: NSView {
    var onDone: ((NSRect?) -> Void)?
    private var origin: NSPoint?
    private var current: NSRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let hint = "Drag to choose the area to record. Press Esc to cancel." as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = hint.size(withAttributes: attrs)
        if let r = current {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()
            let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
            label.draw(at: NSPoint(x: r.minX + 6, y: r.maxY + 6), withAttributes: attrs)
        } else {
            let pill = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.midY - size.height / 2 - 8,
                              width: size.width + 28, height: size.height + 16)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
            hint.draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 8), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let o = origin else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(p.x - o.x), height: abs(p.y - o.y)).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let r = current, r.width >= 40, r.height >= 40 else {
            current = nil
            origin = nil
            needsDisplay = true
            return
        }
        onDone?(r)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: event) }
    }
}
