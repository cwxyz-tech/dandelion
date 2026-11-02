// Dandelion - Screen Recorder math: where the camera zooms, and where the cursor is, at any moment.
// No UI and no video here, so it can be tested on its own.
//
// All positions are fractions of the recorded frame (0...1, top-left origin), so they don't care about
// pixel sizes or Retina scaling.
//
// MIT License. See LICENSE.

import Foundation

struct CursorSample: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
}

struct ClickEvent: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
}

/// Saved next to each raw recording.
struct RecordingInfo: Codable, Equatable {
    var duration: Double
    var width: Int
    var height: Int
    var cursor: [CursorSample]
    var clicks: [ClickEvent]
    var hasAudio: Bool
    var created: Date
}

/// A stretch of time the camera spends zoomed in (it eases in at the start and out at the end).
struct ZoomSpan: Equatable {
    var start: Double
    var end: Double
}

/// The part of the frame on screen: a center and a zoom (1 = the whole frame).
struct Viewport: Equatable {
    var cx: Double
    var cy: Double
    var scale: Double

    var width: Double { 1 / scale }
    var height: Double { 1 / scale }
    var minX: Double { cx - width / 2 }
    var minY: Double { cy - height / 2 }
}

enum ZoomPlanner {
    /// How long before a click the zoom starts, and how long it stays after.
    static let lead = 0.5
    static let hold = 1.8
    /// Clicks closer together than this share one zoom instead of zooming out and back in.
    static let joinGap = 1.4
    /// Time spent easing in or out.
    static let ramp = 0.55

    static func plan(clicks: [ClickEvent], duration: Double) -> [ZoomSpan] {
        guard duration > 0 else { return [] }
        var spans: [ZoomSpan] = []
        for c in clicks.sorted(by: { $0.t < $1.t }) where c.t >= 0 && c.t <= duration {
            let s = ZoomSpan(start: max(0, c.t - lead), end: min(duration, c.t + hold))
            if var last = spans.last, s.start - last.end < joinGap {
                last.end = max(last.end, s.end)
                spans[spans.count - 1] = last
            } else {
                spans.append(s)
            }
        }
        return spans.filter { $0.end - $0.start > 0.05 }
    }

    /// 0 (whole frame) ... 1 (fully zoomed), easing smoothly.
    static func amount(at t: Double, spans: [ZoomSpan]) -> Double {
        var best = 0.0
        for s in spans where t >= s.start && t <= s.end {
            let len = s.end - s.start
            let r = min(ramp, len / 2)
            let rise = r > 0 ? smooth((t - s.start) / r) : 1
            let fall = r > 0 ? smooth((s.end - t) / r) : 1
            best = max(best, min(rise, fall))
        }
        return best
    }

    /// Smoothstep with a gentler start and end (smootherstep).
    static func smooth(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v * v * v * (v * (v * 6 - 15) + 10)
    }

    /// Where the cursor was at `t`, interpolated between samples.
    static func cursor(at t: Double, in samples: [CursorSample]) -> (x: Double, y: Double)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return (first.x, first.y) }
        if t >= last.t { return (last.x, last.y) }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }

    /// The cursor averaged over the last moment, so a drawn cursor glides instead of jittering.
    static func smoothCursor(at t: Double, in samples: [CursorSample], window: Double = 0.09) -> (x: Double, y: Double)? {
        let steps = 6
        var sx = 0.0, sy = 0.0, n = 0.0
        for i in 0..<steps {
            let tt = t - window * Double(i) / Double(steps - 1)
            if let p = cursor(at: tt, in: samples) {
                let w = Double(steps - i)
                sx += p.x * w; sy += p.y * w; n += w
            }
        }
        return n > 0 ? (sx / n, sy / n) : nil
    }

    /// What the camera follows while zoomed: the cursor, slowed down a lot so the camera drifts rather than darts.
    static func focus(at t: Double, in samples: [CursorSample], clicks: [ClickEvent]) -> (x: Double, y: Double) {
        // aim at the nearest click while it's happening, otherwise at a slow average of the cursor
        if let c = clicks.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(c.t - t) < 0.6 {
            if let p = smoothCursor(at: t, in: samples, window: 0.8) {
                let w = 1 - abs(c.t - t) / 0.6
                return (c.x * w + p.x * (1 - w), c.y * w + p.y * (1 - w))
            }
            return (c.x, c.y)
        }
        return smoothCursor(at: t, in: samples, window: 0.8) ?? (0.5, 0.5)
    }

    /// The camera at `t`. Never shows anything outside the recorded frame.
    static func viewport(at t: Double, spans: [ZoomSpan], samples: [CursorSample], clicks: [ClickEvent], maxZoom: Double) -> Viewport {
        let a = amount(at: t, spans: spans)
        let scale = 1 + (max(1, maxZoom) - 1) * a
        let f = focus(at: t, in: samples, clicks: clicks)
        var cx = 0.5 + (f.x - 0.5) * a
        var cy = 0.5 + (f.y - 0.5) * a
        let half = 0.5 / scale
        cx = min(max(cx, half), 1 - half)
        cy = min(max(cy, half), 1 - half)
        return Viewport(cx: cx, cy: cy, scale: scale)
    }
}
