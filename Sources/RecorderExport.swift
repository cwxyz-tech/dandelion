// Dandelion - Screen Recorder export: turns a raw recording into a polished video.
// Each frame gets a background, padding, rounded corners and a soft shadow, the camera zooms smoothly
// toward your clicks, and a crisp cursor (with a ripple on every click) is drawn on top.
// The same composer draws the live preview, so the preview is exactly what you'll get.
// MIT License. See LICENSE.

import AppKit
import AVFoundation
import CoreImage
import CoreMedia

struct ExportStyle: Equatable {
    var framed = true
    var background = 0
    /// Space around the recording, as a fraction of the video's height.
    var padding = 0.08
    /// Corner rounding, as a fraction of the video's height.
    var corner = 0.016
    var zoom = true
    var zoomAmount = 1.9
    var showCursor = true
    var cursorScale = 1.5
    var ripples = true
    var height = 1080
}

enum Backdrops {
    static let presets: [(name: String, a: (Double, Double, Double), b: (Double, Double, Double))] = [
        ("Dandelion", (0.99, 0.78, 0.31), (0.95, 0.42, 0.25)),
        ("Dusk", (0.36, 0.26, 0.85), (0.92, 0.36, 0.55)),
        ("Ocean", (0.13, 0.55, 0.92), (0.16, 0.85, 0.75)),
        ("Meadow", (0.55, 0.85, 0.35), (0.12, 0.55, 0.45)),
        ("Graphite", (0.28, 0.3, 0.36), (0.1, 0.11, 0.14)),
        ("Paper", (0.97, 0.96, 0.94), (0.88, 0.87, 0.85)),
    ]

    static func colors(_ i: Int) -> (CIColor, CIColor) {
        let p = presets[max(0, min(i, presets.count - 1))]
        return (CIColor(red: p.a.0, green: p.a.1, blue: p.a.2), CIColor(red: p.b.0, green: p.b.1, blue: p.b.2))
    }
}

/// Draws one finished frame from one raw frame. Make one per export (or per preview style); it caches
/// everything that doesn't change from frame to frame.
final class FrameComposer {
    let style: ExportStyle
    let info: RecordingInfo
    let canvas: CGRect
    let content: CGRect
    private let sourceSize: CGSize
    private let spans: [ZoomSpan]
    private let backdrop: CIImage
    private let mask: CIImage?
    private let cursor: CIImage
    private let cursorTip: CGPoint
    private let ring: CIImage

    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    init(style: ExportStyle, info: RecordingInfo, sourceSize: CGSize) {
        self.style = style
        self.info = info
        self.sourceSize = sourceSize
        let H = Double(max(240, style.height))
        let aspect = sourceSize.width / max(sourceSize.height, 1)
        let W: Double = style.framed ? H * 16 / 9 : H * aspect
        let even = { (v: Double) in max(2, (v / 2).rounded(.down) * 2) }
        let canvas = CGRect(x: 0, y: 0, width: even(W), height: even(H))
        self.canvas = canvas

        let content: CGRect
        if style.framed {
            let pad = canvas.height * style.padding
            let box = canvas.insetBy(dx: pad, dy: pad)
            let fit = min(box.width / sourceSize.width, box.height / sourceSize.height)
            let size = CGSize(width: sourceSize.width * fit, height: sourceSize.height * fit)
            content = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                             width: size.width, height: size.height).integral
        } else {
            content = canvas
        }
        self.content = content
        spans = style.zoom ? ZoomPlanner.plan(clicks: info.clicks, duration: info.duration) : []

        // background with the shadow already in it
        let (c0, c1) = Backdrops.colors(style.background)
        var bg = CIImage(color: .black).cropped(to: canvas)
        if style.framed, let g = CIFilter(name: "CILinearGradient") {
            g.setValue(CIVector(x: 0, y: canvas.height), forKey: "inputPoint0")
            g.setValue(CIVector(x: canvas.width, y: 0), forKey: "inputPoint1")
            g.setValue(c0, forKey: "inputColor0")
            g.setValue(c1, forKey: "inputColor1")
            if let out = g.outputImage { bg = out.cropped(to: canvas) }
        }
        let radius = style.framed ? canvas.height * style.corner : 0
        if style.framed {
            let m = FrameComposer.roundedMask(canvas: canvas, rect: content, radius: radius)
            mask = m
            let shadowRadius = canvas.height * 0.022
            let shadow = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.42),
            ])
                .clampedToExtent()
                .applyingGaussianBlur(sigma: shadowRadius)
                .transformed(by: CGAffineTransform(translationX: 0, y: -canvas.height * 0.008))
                .cropped(to: canvas)
            bg = shadow.composited(over: bg)
        } else {
            mask = nil
        }
        backdrop = bg

        let unit = canvas.height / 1080 * style.cursorScale
        let (img, tip) = FrameComposer.cursorImage(unit: unit)
        cursor = img
        cursorTip = tip
        ring = FrameComposer.ringImage(size: 80 * unit)
    }

    /// The finished frame at `t` seconds, from that moment's raw frame.
    func compose(_ source: CIImage, at t: Double) -> CIImage {
        let sw = sourceSize.width, sh = sourceSize.height
        let vp = style.zoom
            ? ZoomPlanner.viewport(at: t, spans: spans, samples: info.cursor, clicks: info.clicks, maxZoom: style.zoomAmount)
            : Viewport(cx: 0.5, cy: 0.5, scale: 1)
        // the part of the raw frame in view, in Core Image's bottom-up pixels
        let vr = CGRect(x: vp.minX * sw, y: sh - (vp.minY * sh + sh / vp.scale), width: sw / vp.scale, height: sh / vp.scale)
        let sx = content.width / vr.width, sy = content.height / vr.height
        let src = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let placed = src.clampedToExtent()
            .cropped(to: vr)
            .transformed(by: CGAffineTransform(translationX: -vr.minX, y: -vr.minY)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: content.minX, y: content.minY)))
            .cropped(to: content)

        var frame: CIImage
        if let mask {
            frame = placed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: backdrop,
                kCIInputMaskImageKey: mask,
            ])
        } else {
            frame = placed.composited(over: backdrop)
        }

        // where a point of the raw frame lands in the finished one
        func project(_ x: Double, _ y: Double) -> CGPoint? {
            let u = (x - vp.minX) * vp.scale, v = (y - vp.minY) * vp.scale
            guard u >= -0.02, u <= 1.02, v >= -0.02, v <= 1.02 else { return nil }
            return CGPoint(x: content.minX + u * content.width, y: content.maxY - v * content.height)
        }

        let grow = 1 + (vp.scale - 1) * 0.3
        if style.ripples {
            for c in info.clicks where t >= c.t && t - c.t < 0.55 {
                guard let p = project(c.x, c.y) else { continue }
                let k = (t - c.t) / 0.55
                let s = (0.35 + k * 0.9) * grow
                let alpha = (1 - k) * 0.8
                let r = ring.transformed(by: CGAffineTransform(scaleX: s, y: s))
                let placedRing = r.transformed(by: CGAffineTransform(translationX: p.x - r.extent.width / 2 - r.extent.minX,
                                                                     y: p.y - r.extent.height / 2 - r.extent.minY))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                frame = placedRing.composited(over: frame)
            }
        }
        if style.showCursor, let c = ZoomPlanner.smoothCursor(at: t, in: info.cursor), let p = project(c.x, c.y) {
            let pressed = info.clicks.contains { t >= $0.t && t - $0.t < 0.12 }
            let s = grow * (pressed ? 0.88 : 1)
            let img = cursor.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let tip = CGPoint(x: cursorTip.x * s, y: cursorTip.y * s)
            frame = img.transformed(by: CGAffineTransform(translationX: p.x - tip.x, y: p.y - tip.y)).composited(over: frame)
        }
        return frame.cropped(to: canvas)
    }

    // MARK: pieces drawn once

    private static func bitmap(_ size: CGSize, draw: (CGContext) -> Void) -> CIImage {
        let w = max(1, Int(size.width.rounded(.up))), h = max(1, Int(size.height.rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        draw(ctx)
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }

    static func roundedMask(canvas: CGRect, rect: CGRect, radius: CGFloat) -> CIImage {
        bitmap(canvas.size) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }

    /// A classic Mac arrow, white-edged with a soft shadow. Returns the image and where its tip is.
    static func cursorImage(unit u: CGFloat) -> (CIImage, CGPoint) {
        // the arrow's outline in a 13 × 21 box, top-left origin
        let pts: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4, y: 13.2), CGPoint(x: 6.8, y: 19.6),
                              CGPoint(x: 9.4, y: 18.5), CGPoint(x: 6.7, y: 12.2), CGPoint(x: 12, y: 12.2)]
        let s = u * 1.55
        let pad = 6 * u
        let size = CGSize(width: 13 * s + pad * 2, height: 21 * s + pad * 2)
        let img = bitmap(size) { ctx in
            let path = CGMutablePath()
            for (i, p) in pts.enumerated() {
                let q = CGPoint(x: pad + p.x * s, y: size.height - pad - p.y * s)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.closeSubpath()
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * u), blur: 4 * u, color: CGColor(gray: 0, alpha: 0.45))
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(2.6 * u)
            ctx.strokePath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
            ctx.fillPath()
        }
        return (img, CGPoint(x: pad, y: size.height - pad))
    }

    static func ringImage(size: CGFloat) -> CIImage {
        bitmap(CGSize(width: size, height: size)) { ctx in
            let w = size * 0.07
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(w)
            ctx.setShadow(offset: .zero, blur: w, color: CGColor(gray: 0, alpha: 0.35))
            ctx.strokeEllipse(in: CGRect(x: w, y: w, width: size - 2 * w, height: size - 2 * w))
        }
    }
}

enum RecordingExporter {
    /// Renders `raw` into a finished .mp4 at `out`. Calls `progress` with 0...1 from a background thread.
    static func export(raw: URL, info: RecordingInfo, style: ExportStyle, to out: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: raw)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("The recording has no video.")
        }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let natural = try await vTrack.load(.naturalSize)
        let duration = max(0.01, CMTimeGetSeconds(try await asset.load(.duration)))
        let audioFormat = try await aTrack?.load(.formatDescriptions).first

        let composer = FrameComposer(style: style, info: info, sourceSize: natural)
        let W = Int(composer.canvas.width), H = Int(composer.canvas.height)

        try? FileManager.default.removeItem(at: out)
        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        if let aTrack {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)   // pass the AAC through untouched
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: W,
            AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(6_000_000, W * H * 6),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W,
            kCVPixelBufferHeightKey as String: H,
        ])
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); aIn = input } else { aOut = nil }
        }

        guard reader.startReading() else { throw RecorderError.message(reader.error?.localizedDescription ?? "The recording couldn't be read.") }
        guard writer.startWriting() else { throw RecorderError.message(writer.error?.localizedDescription ?? "The video couldn't be written.") }
        writer.startSession(atSourceTime: .zero)

        let ctx = FrameComposer.context
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let group = DispatchGroup()
        let vQueue = DispatchQueue(label: "dandelion.export.video")
        let aQueue = DispatchQueue(label: "dandelion.export.audio")
        let box = ExportState()

        group.enter()
        vIn.requestMediaDataWhenReady(on: vQueue) {
            while vIn.isReadyForMoreMediaData {
                guard !box.failed, let sample = vOut.copyNextSampleBuffer() else {
                    vIn.markAsFinished()
                    group.leave()
                    return
                }
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let t = CMTimeGetSeconds(pts)
                let frame = composer.compose(CIImage(cvPixelBuffer: pixels), at: t)
                guard let pool = adaptor.pixelBufferPool else { box.failed = true; continue }
                var outBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                guard let target = outBuffer else { box.failed = true; continue }
                ctx.render(frame, to: target, bounds: composer.canvas, colorSpace: space)
                if !adaptor.append(target, withPresentationTime: pts) { box.failed = true }
                progress(min(1, t / duration))
            }
        }
        if let aIn, let aOut {
            group.enter()
            aIn.requestMediaDataWhenReady(on: aQueue) {
                while aIn.isReadyForMoreMediaData {
                    guard !box.failed, let sample = aOut.copyNextSampleBuffer() else {
                        aIn.markAsFinished()
                        group.leave()
                        return
                    }
                    if !aIn.append(sample) { box.failed = true }
                }
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { cont.resume() }
        }
        if box.failed || reader.status == .failed {
            writer.cancelWriting()
            throw RecorderError.message(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "The export didn't finish.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecorderError.message(writer.error?.localizedDescription ?? "The export didn't finish.")
        }
        progress(1)
    }

    /// One finished frame, for the preview.
    static func previewFrame(raw: URL, info: RecordingInfo, style: ExportStyle, at t: Double) async -> CGImage? {
        let asset = AVURLAsset(url: raw)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        guard let result = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { return nil }
        let (cg, actual) = (result.image, result.actualTime)
        var previewStyle = style
        previewStyle.height = min(style.height, 720)
        let composer = FrameComposer(style: previewStyle, info: info, sourceSize: CGSize(width: cg.width, height: cg.height))
        let frame = composer.compose(CIImage(cgImage: cg), at: CMTimeGetSeconds(actual))
        return FrameComposer.context.createCGImage(frame, from: composer.canvas)
    }
}

/// Shared between the two export queues.
private final class ExportState: @unchecked Sendable {
    private let lock = NSLock()
    private var _failed = false
    var failed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failed }
        set { lock.lock(); _failed = newValue; lock.unlock() }
    }
}
