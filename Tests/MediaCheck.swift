// Dandelion - checks for screenshot markup and the Screen Recorder's export, on real pixels and real video.
// Runs on a real Mac in CI (see Tests/run.sh).

import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import Darwin
import Foundation

private func check(_ ok: Bool, _ what: String) { ScanCheck.check(ok, what) }

/// RGBA pixels, top row first.
private struct Pixels {
    let w: Int, h: Int
    let data: [UInt8]

    init?(_ image: CGImage) {
        w = image.width
        h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        data = buf
    }

    func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
}

/// Holds a result written from async work.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Runs async work from the synchronous checks.
private func wait(_ body: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task.detached { await body(); done.signal() }
    done.wait()
}

enum MarkupCheck {
    static func run() {
        // a white 400 × 300 picture with black and white stripes where the blur will go
        let w = 400, h = 300
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { check(false, "test image"); return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 20, to: 120, by: 4) { ctx.fill(CGRect(x: x, y: h - 250, width: 2, height: 100)) }
        guard let base = ctx.makeImage() else { check(false, "test image"); return }

        let blurRect = CGRect(x: 20, y: 150, width: 100, height: 100)
        let marks = [
            Mark(kind: .arrow, a: CGPoint(x: 200, y: 40), b: CGPoint(x: 360, y: 40), color: 0),
            Mark(kind: .box, a: CGPoint(x: 220, y: 120), b: CGPoint(x: 380, y: 200), color: 4),
            Mark(kind: .text, a: CGPoint(x: 20, y: 20), b: CGPoint(x: 20, y: 20), color: 3, text: "Hi"),
            Mark(kind: .blur, a: blurRect.origin, b: CGPoint(x: blurRect.maxX, y: blurRect.maxY), color: 0),
        ]
        var pixelated: [UUID: CGImage] = [:]
        if let piece = MarkDrawer.pixelate(base, rect: blurRect) { pixelated[marks[3].id] = piece }
        check(pixelated.count == 1, "blur makes a pixelated piece")

        guard let out = MarkDrawer.render(base, marks: marks, pixelated: pixelated), let px = Pixels(out) else {
            check(false, "markup renders"); return
        }
        check(out.width == w && out.height == h, "the saved picture keeps its full size")
        let arrow = px.at(280, 40)
        check(arrow.r > 200 && arrow.g < 110 && arrow.b < 110, "the arrow is drawn in red where it should be \(arrow)")
        let edge = px.at(220, 160)
        check(edge.b > 150 && edge.r < 120, "the box outline is blue \(edge)")
        let inside = px.at(300, 160)
        check(inside.r > 235 && inside.g > 235 && inside.b > 235, "the inside of a box stays clear \(inside)")
        let pill = px.at(23, 32)
        check(pill.g > pill.r + 40 && pill.g > pill.b, "text sits on a colored label \(pill)")
        let b1 = px.at(42, 170), b2 = px.at(43, 170)
        check(b1 == b2 && b1.r > 50 && b1.r < 210, "blurred stripes become flat grey blocks, so they can't be read \(b1) \(b2)")
        let far = px.at(390, 290)
        check(far.r > 245 && far.g > 245 && far.b > 245, "untouched parts are unchanged")
        check(MarkDrawer.render(base, marks: [], pixelated: [:]).flatMap { Pixels($0)?.at(200, 40) } .map { $0.r > 245 } == true,
              "no marks means no changes")
    }
}

enum ExportCheck {
    static func run() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "dandelion-export-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("raw.mov")
        guard makeRecording(raw, width: 640, height: 400, seconds: 2) else { check(false, "a test recording can be made"); return }
        check(true, "a test recording can be made")

        let info = RecordingInfo(duration: 2, width: 640, height: 400,
                                 cursor: (0...40).map { CursorSample(t: Double($0) * 0.05, x: 0.2 + Double($0) * 0.012, y: 0.3) },
                                 clicks: [ClickEvent(t: 0.8, x: 0.7, y: 0.3)], hasAudio: true, created: Date())

        // framed, with zoom, cursor and ripples
        let framed = dir.appendingPathComponent("framed.mp4")
        var style = ExportStyle()
        style.height = 360
        let failure = Box<String?>(nil)
        let lastProgress = Box(0.0)
        wait {
            do { try await RecordingExporter.export(raw: raw, info: info, style: style, to: framed) { p in lastProgress.value = p } }
            catch let e { failure.value = e.localizedDescription }
        }
        check(failure.value == nil, "the export finishes (\(failure.value ?? "ok"))")
        check(lastProgress.value == 1, "progress reaches 100%")
        let (size, length, hasAudio) = describe(framed)
        check(size == CGSize(width: 640, height: 360), "a framed export is 16:9 at the chosen height (\(size))")
        check(abs(length - 2) < 0.25, "the export is as long as the recording (\(length)s)")
        check(hasAudio, "the sound comes through")

        if let frame = frameAt(framed, seconds: 1.0), let px = Pixels(frame) {
            let corner = px.at(6, 6)
            check(corner.r > 150 && corner.b < 150, "the background is the chosen gradient \(corner)")
            let middle = px.at(320, 180)
            check(middle != corner, "the recording sits on top of the background")
        } else {
            check(false, "a frame of the export can be read")
        }

        // plain: no frame, keeps the recording's shape
        let plain = dir.appendingPathComponent("plain.mp4")
        var plainStyle = ExportStyle()
        plainStyle.framed = false
        plainStyle.zoom = false
        plainStyle.height = 360
        failure.value = nil
        wait {
            do { try await RecordingExporter.export(raw: raw, info: info, style: plainStyle, to: plain) { _ in } }
            catch let e { failure.value = e.localizedDescription }
        }
        let (plainSize, _, _) = describe(plain)
        check(failure.value == nil && plainSize == CGSize(width: 576, height: 360), "an unframed export keeps the recording's shape (\(plainSize))")

        let preview = Box<CGImage?>(nil)
        wait { preview.value = await RecordingExporter.previewFrame(raw: raw, info: info, style: style, at: 0.9) }
        check(preview.value?.width == 640 && preview.value?.height == 360, "the preview matches the export")

        try? FileManager.default.removeItem(at: dir)
    }

    private static func describe(_ url: URL) -> (CGSize, Double, Bool) {
        let result = Box((CGSize.zero, 0.0, false))
        wait {
            let asset = AVURLAsset(url: url)
            let v: AVAssetTrack? = (try? await asset.loadTracks(withMediaType: .video))?.first
            let a: AVAssetTrack? = (try? await asset.loadTracks(withMediaType: .audio))?.first
            var size = CGSize.zero
            if let v, let s = try? await v.load(.naturalSize) { size = s }
            var d = 0.0
            if let t = try? await asset.load(.duration) { d = CMTimeGetSeconds(t) }
            result.value = (size, d, a != nil)
        }
        return result.value
    }

    private static func frameAt(_ url: URL, seconds: Double) -> CGImage? {
        let image = Box<CGImage?>(nil)
        wait {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            image.value = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        }
        return image.value
    }

    /// A short movie like a raw recording: a moving square on a changing background, plus silent audio.
    private static func makeRecording(_ url: URL, width: Int, height: Int, seconds: Int) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000, AVEncoderBitRateKey: 64_000,
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { return false }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)

        let fps = 30
        let audioChunk = 1024
        var audioFrame = 0
        let totalAudio = 48_000 * seconds
        for f in 0..<(fps * seconds) {
            let t = CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))
            var pb: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else {
                return false
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let sq = 40 + f * 8
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * row + x * 4
                    let inSquare = x >= sq && x < sq + 80 && y >= 150 && y < 230
                    p[0] = inSquare ? 255 : UInt8(80 + y / 4)          // blue
                    p[1] = inSquare ? 255 : UInt8(40 + f * 2)          // green
                    p[2] = inSquare ? 255 : UInt8(30)                  // red
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !video.isReadyForMoreMediaData { usleep(1000) }
            guard adaptor.append(buffer, withPresentationTime: t) else { return false }

            // keep the sound up to the same time
            let until = min(totalAudio, (f + 1) * 48_000 / fps)
            while audioFrame < until, let format {
                let n = min(audioChunk, totalAudio - audioFrame)
                let bytes = n * 2
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                   flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                guard let block else { return false }
                CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                     sampleCount: n, presentationTimeStamp: CMTime(value: CMTimeValue(audioFrame), timescale: 48_000),
                                                                     packetDescriptions: nil, sampleBufferOut: &sample)
                guard let sample else { return false }
                while !audio.isReadyForMoreMediaData { usleep(1000) }
                guard audio.append(sample) else { return false }
                audioFrame += n
            }
        }
        video.markAsFinished()
        audio.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}
