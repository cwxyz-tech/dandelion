// Dandelion - checks for the Time Tracker engine and the Screen Recorder's zoom math.
// Runs on a real Mac in CI (see Tests/run.sh).

import Darwin
import Foundation

private func check(_ ok: Bool, _ what: String) { ScanCheck.check(ok, what) }

enum TimeCheck {
    static func run() {
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }

        var r = TimeRecorder()
        r.switchTo(app: "com.apple.Safari", name: "Safari", category: .browsing, at: at(0))
        r.switchTo(app: "com.apple.Safari", name: "Safari", category: .browsing, at: at(5))     // same app again: no new segment
        r.switchTo(app: "com.apple.dt.Xcode", name: "Xcode", category: .development, at: at(10))
        r.switchTo(app: "com.apple.Notes", name: "Notes", category: .productivity, at: at(40))
        r.switchTo(app: "com.apple.Mail", name: "Mail", category: .communication, at: at(40) + 1)   // Notes for 1 s: dropped
        r.pause(at: at(55))
        let segs = r.takeFinished()
        check(segs.map { $0.name } == ["Safari", "Xcode", "Mail"], "segments follow the front app, quick flicks dropped (\(segs.map { $0.name }))")
        check(abs(segs[0].seconds - 600) < 0.01 && abs(segs[1].seconds - 1800) < 0.01, "segment lengths are right")
        check(r.current == nil && r.takeFinished().isEmpty, "pausing stops counting")

        // flushing keeps the app going but hands off what's done so far
        r.switchTo(app: "com.apple.Safari", name: "Safari", category: .browsing, at: at(60))
        r.flush(at: at(61))
        check(r.takeFinished().count == 1 && r.current?.start == at(61), "a flush saves progress and carries on")

        // midnight
        let late = cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 23, minute: 30))!
        let split = TimeRecorder.splitAtMidnight(TimeSegment(app: "a", name: "A", category: .other, start: late, end: late.addingTimeInterval(3600)))
        check(split.count == 2 && abs(split[0].seconds - 1800) < 0.01 && TimeStore.dayKey(split[1].start) == "2026-03-11",
              "a segment over midnight is split between the two days")

        // saving
        let folder = URL(fileURLWithPath: NSTemporaryDirectory() + "dandelion-time-\(getpid())")
        try? FileManager.default.removeItem(at: folder)
        try? TimeStore.append(segs, to: folder)
        let more = TimeSegment(app: "com.apple.Mail", name: "Mail", category: .communication, start: at(55), end: at(70))
        try? TimeStore.append([more], to: folder)
        let loaded = TimeStore.load(day: "2026-03-10", from: folder)
        check(loaded.count == 3 && abs((loaded.last?.seconds ?? 0) - 15 * 60 - 15 * 60 + 1) < 2,
              "saved days load back, and a segment that continues the last one is joined onto it (\(loaded.count))")
        var st = stat()
        check(stat(TimeStore.url(day: "2026-03-10", in: folder).path, &st) == 0 && (st.st_mode & 0o777) == 0o600, "time files are private to you")
        TimeStore.delete(day: "2026-03-10", from: folder)
        check(TimeStore.load(day: "2026-03-10", from: folder).isEmpty, "a day's history can be deleted")
        try? FileManager.default.removeItem(at: folder)

        // stats
        let apps = TimeStats.byApp(segs)
        check(apps.first?.name == "Xcode" && apps.count == 3, "apps are ranked by time")
        let hours = TimeStats.byHour([TimeSegment(app: "x", name: "X", category: .development, start: at(50), end: at(80))], day: day)
        let nine = hours.filter { $0.index == 9 }.reduce(0) { $0 + $1.seconds }
        let ten = hours.filter { $0.index == 10 }.reduce(0) { $0 + $1.seconds }
        check(abs(nine - 600) < 0.01 && abs(ten - 1200) < 0.01, "time crossing an hour is shared between the hours")
        check(TimeStats.format(5400) == "1h 30m" && TimeStats.format(2700) == "45m" && TimeStats.format(30) == "30s", "durations read naturally")

        // categories
        check(TimeCategory.of(bundleID: "com.apple.dt.Xcode", declared: nil) == .development, "Xcode is development")
        check(TimeCategory.of(bundleID: "com.example.unknown", declared: "public.app-category.games") == .entertainment,
              "unknown apps use the category they declare")
        check(TimeCategory.of(bundleID: "com.example.unknown", declared: nil) == .other, "otherwise they're Other")
    }
}

enum ZoomCheck {
    static func run() {
        let clicks = [ClickEvent(t: 2, x: 0.9, y: 0.9), ClickEvent(t: 3, x: 0.8, y: 0.8), ClickEvent(t: 10, x: 0.1, y: 0.1)]
        let spans = ZoomPlanner.plan(clicks: clicks, duration: 12)
        check(spans.count == 2, "clicks close together share one zoom (\(spans.count))")
        check(abs(spans[0].start - 1.5) < 0.001 && abs(spans[0].end - 4.8) < 0.001, "a zoom starts just before the click and holds after")
        check(abs(spans[1].end - 11.8) < 0.001, "zooms stay inside the recording")
        check(ZoomPlanner.amount(at: 0.5, spans: spans) == 0, "no zoom before the first click")
        check(abs(ZoomPlanner.amount(at: 3, spans: spans) - 1) < 0.001, "fully zoomed in the middle")
        let rising = (0...10).map { ZoomPlanner.amount(at: 1.5 + Double($0) * 0.05, spans: spans) }
        check(zip(rising, rising.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 }, "the zoom eases in without jumping back")

        let samples = [CursorSample(t: 0, x: 0, y: 0), CursorSample(t: 1, x: 1, y: 0.5)]
        let mid = ZoomPlanner.cursor(at: 0.5, in: samples)
        check(mid != nil && abs(mid!.x - 0.5) < 1e-9 && abs(mid!.y - 0.25) < 1e-9, "the cursor is interpolated between samples")

        // the camera never shows outside the frame, even zoomed into a corner
        let vp = ZoomPlanner.viewport(at: 3, spans: spans, samples: [CursorSample(t: 0, x: 1, y: 1)], clicks: clicks, maxZoom: 2)
        check(abs(vp.scale - 2) < 0.001, "full zoom reaches the chosen amount")
        check(vp.minX >= -1e-9 && vp.minY >= -1e-9 && vp.minX + vp.width <= 1 + 1e-9 && vp.minY + vp.height <= 1 + 1e-9,
              "the zoomed view stays inside the recording")
        let still = ZoomPlanner.viewport(at: 0.2, spans: spans, samples: samples, clicks: clicks, maxZoom: 2)
        check(still == Viewport(cx: 0.5, cy: 0.5, scale: 1), "unzoomed shows the whole frame")
        check(ZoomPlanner.plan(clicks: [], duration: 5).isEmpty, "no clicks, no zoom")
    }
}
