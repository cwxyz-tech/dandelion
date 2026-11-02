// Dandelion - the Time Tracker: watches which app is in front (while tracking is on) and charts your day and week.
// MIT License. See LICENSE.
//
// View state lives in the model (no @State): in the macOS 26 SDK @State is a macro, and the
// Command Line Tools don't ship the plugin that expands it.

import AppKit
import Charts
import CoreGraphics
import SwiftUI

@MainActor
final class TimeTrackerModel: ObservableObject {
    enum Range: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week"
        var id: String { rawValue }
    }

    @Published var tracking: Bool {
        didSet {
            UserDefaults.standard.set(tracking, forKey: "timeTracking")
            tracking ? resume() : stop()
        }
    }
    @Published var range: Range = .day
    /// Any moment inside the day or week being shown.
    @Published var anchor = Date()
    @Published private(set) var segments: [TimeSegment] = []
    @Published private(set) var idle = false
    @Published var confirmDelete = false

    weak var app: AppState?
    private var recorder = TimeRecorder()
    private var observers: [NSObjectProtocol] = []
    private var tick: Timer?
    private var asleep = false

    /// Away from the keyboard and mouse this long counts as a break, not time in the app.
    static let idleAfter: TimeInterval = 5 * 60

    init() {
        tracking = UserDefaults.standard.bool(forKey: "timeTracking")
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self.frontmostChanged(running) }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.asleep = true; self.pauseNow(at: Date()) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.asleep = false; self.resume() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.pauseNow(at: Date()) }
        })
        if tracking { resume() }
        reload()
    }

    // MARK: recording

    private func resume() {
        guard tracking, !asleep else { return }
        idle = false
        frontmostChanged(NSWorkspace.shared.frontmostApplication)
        if tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { self.onTick() }
            }
        }
    }

    private func stop() {
        pauseNow(at: Date())
        tick?.invalidate()
        tick = nil
    }

    private func frontmostChanged(_ running: NSRunningApplication?) {
        guard tracking, !asleep, !idle, let running else { return }
        let id = running.bundleIdentifier ?? running.localizedName ?? "unknown"
        let name = running.localizedName ?? id
        var declared: String?
        if let url = running.bundleURL, let info = Bundle(url: url)?.infoDictionary {
            declared = info["LSApplicationCategoryType"] as? String
        }
        recorder.switchTo(app: id, name: name, category: TimeCategory.of(bundleID: id, declared: declared), at: Date())
    }

    private func pauseNow(at date: Date) {
        recorder.pause(at: date)
        persist()
    }

    private func onTick() {
        guard tracking else { return }
        let away = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if away >= Self.idleAfter {
            if !idle {
                idle = true
                pauseNow(at: Date().addingTimeInterval(-away))   // leave the idle stretch out
            }
            return
        }
        if idle {
            idle = false
            frontmostChanged(NSWorkspace.shared.frontmostApplication)
            return
        }
        recorder.flush(at: Date())
        persist()
    }

    private func persist() {
        let done = recorder.takeFinished()
        guard !done.isEmpty else { return }
        do { try TimeStore.append(done) } catch {
            app?.alertMessage = "Time Tracker couldn't save: \(error.localizedDescription)"
        }
        reload()
    }

    // MARK: what's shown

    var days: [Date] {
        let cal = Calendar.current
        switch range {
        case .day:
            return [cal.startOfDay(for: anchor)]
        case .week:
            let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? cal.startOfDay(for: anchor)
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        }
    }

    var title: String {
        let f = DateFormatter()
        let cal = Calendar.current
        switch range {
        case .day:
            if cal.isDateInToday(anchor) { return "Today" }
            if cal.isDateInYesterday(anchor) { return "Yesterday" }
            f.dateFormat = "EEEE, MMMM d"
            return f.string(from: anchor)
        case .week:
            let d = days
            f.dateFormat = "MMM d"
            return "\(f.string(from: d.first ?? anchor)) – \(f.string(from: d.last ?? anchor))"
        }
    }

    var isCurrent: Bool {
        let cal = Calendar.current
        return range == .day ? cal.isDateInToday(anchor) : cal.isDate(anchor, equalTo: Date(), toGranularity: .weekOfYear)
    }

    func step(_ by: Int) {
        let cal = Calendar.current
        anchor = cal.date(byAdding: range == .day ? .day : .weekOfYear, value: by, to: anchor) ?? anchor
        reload()
    }

    /// Only for the README screenshot: a made-up day, never saved.
    private var sample = false
    func showSample() {
        sample = true
        range = .day
        anchor = Date()
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(8.5 * 3600)
        let plan: [(String, String, TimeCategory, Double)] = [
            ("com.apple.mail", "Mail", .communication, 20), ("com.apple.Safari", "Safari", .browsing, 25),
            ("com.apple.dt.Xcode", "Xcode", .development, 95), ("com.apple.MobileSMS", "Messages", .communication, 10),
            ("com.apple.dt.Xcode", "Xcode", .development, 70), ("com.apple.Safari", "Safari", .browsing, 30),
            ("com.apple.Music", "Music", .entertainment, 25), ("com.apple.Notes", "Notes", .productivity, 35),
            ("com.apple.Terminal", "Terminal", .development, 45), ("com.apple.dt.Xcode", "Xcode", .development, 80),
            ("com.apple.mail", "Mail", .communication, 15), ("com.apple.Preview", "Preview", .productivity, 20),
            ("com.apple.Safari", "Safari", .browsing, 40), ("com.apple.Terminal", "Terminal", .development, 30),
        ]
        var t = start
        var segs: [TimeSegment] = []
        for (i, p) in plan.enumerated() {
            let end = t.addingTimeInterval(p.3 * 60)
            segs.append(TimeSegment(app: p.0, name: p.1, category: p.2, start: t, end: end))
            t = end.addingTimeInterval(i == 5 ? 45 * 60 : 0)   // a lunch break
        }
        segments = segs
    }

    func reload() {
        guard !sample else { return }
        // include the segment still running, so the numbers are live
        var segs = days.flatMap { TimeStore.load(day: TimeStore.dayKey($0)) }
        if tracking, let c = recorder.current {
            let live = TimeSegment(app: c.app, name: c.name, category: c.category, start: c.start, end: Date())
            let wanted = Set(days.map { TimeStore.dayKey($0) })
            segs += TimeRecorder.splitAtMidnight(live).filter { wanted.contains(TimeStore.dayKey($0.start)) }
        }
        segments = segs
    }

    func deleteShown() {
        for d in days { TimeStore.delete(day: TimeStore.dayKey(d)) }
        if isCurrent { recorder.pause(at: Date()); _ = recorder.takeFinished(); if tracking { resume() } }
        reload()
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: TimeStore.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(TimeStore.folder)
    }

    static func color(_ c: TimeCategory) -> Color {
        switch c {
        case .development: return Color(red: 0.36, green: 0.42, blue: 0.95)
        case .productivity: return Color(red: 0.2, green: 0.7, blue: 0.5)
        case .communication: return Color(red: 0.98, green: 0.6, blue: 0.2)
        case .browsing: return Color(red: 0.25, green: 0.65, blue: 0.95)
        case .creative: return Color(red: 0.88, green: 0.35, blue: 0.62)
        case .entertainment: return Color(red: 0.62, green: 0.42, blue: 0.95)
        case .other: return Color.gray
        }
    }

    static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

struct TimeTrackerView: View {
    @EnvironmentObject var model: TimeTrackerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ToolHeader(tool: .timeTracker, subtitle: "See which apps your day actually goes to. Everything stays on your Mac.")
                trackingCard
                rangeBar
                if model.segments.isEmpty {
                    emptyState
                } else {
                    summary
                    chartCard
                    appsCard
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.reload() }
        .alert("Delete this \(model.range == .day ? "day's" : "week's") history?", isPresented: Binding(
            get: { model.confirmDelete }, set: { model.confirmDelete = $0 })
        ) {
            Button("Delete", role: .destructive) { model.deleteShown() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from your Mac for good.")
        }
    }

    private var trackingCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.tracking ? (model.idle ? "pause.circle.fill" : "record.circle") : "clock.badge.xmark")
                .font(.system(size: 24))
                .foregroundStyle(model.tracking ? Tool.timeTracker.tint : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.tracking ? (model.idle ? "Paused while you're away" : "Tracking your time") : "Track my time")
                    .font(.system(size: 13, weight: .semibold))
                Text("Logs which app is in front, and for how long. Only app names and times, never window titles or what's on screen. Breaks of 5 minutes or more aren't counted. Close the window and it keeps going from the menu bar.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.tracking }, set: { v in withAnimation { model.tracking = v } }))
                .toggleStyle(.switch).labelsHidden()
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var rangeBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { model.range }, set: { model.range = $0; model.reload() })) {
                ForEach(TimeTrackerModel.Range.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.isCurrent)
            Text(model.title).font(.system(size: 15, weight: .semibold))
            Spacer()
            Menu {
                Button("Delete This \(model.range.rawValue)'s History…") { model.confirmDelete = true }
                    .disabled(model.segments.isEmpty)
                Button("Show Data in Finder") { model.openFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(model.tracking ? "Nothing recorded yet for this \(model.range.rawValue.lowercased())." : "Turn on tracking to start seeing where your time goes.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

    private var summary: some View {
        let total = TimeStats.total(model.segments)
        let cats = TimeStats.byCategory(model.segments)
        return HStack(alignment: .top, spacing: 14) {
            stat(TimeStats.format(total), model.range == .day ? "on your Mac" : "this week")
            if let top = TimeStats.byApp(model.segments).first {
                stat(top.name, "most used, \(TimeStats.format(top.seconds))")
            }
            if let c = cats.first {
                stat(c.0.rawValue, "top category, \(Int((c.1 / max(total, 1) * 100).rounded()))%")
            }
        }
    }

    private func stat(_ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(big).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1)
            Text(small).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var chartCard: some View {
        let cats = TimeCategory.allCases
        return VStack(alignment: .leading, spacing: 10) {
            Text(model.range == .day ? "By hour" : "By day").font(.system(size: 13, weight: .semibold))
            Group {
                if model.range == .day {
                    Chart(TimeStats.byHour(model.segments, day: model.anchor)) { slot in
                        BarMark(x: .value("Hour", Double(slot.index)), y: .value("Minutes", slot.seconds / 60), width: .ratio(0.75))
                            .foregroundStyle(by: .value("Category", slot.category.rawValue))
                            .cornerRadius(3)
                    }
                    .chartXScale(domain: -0.5...23.5)
                    .chartXAxis {
                        AxisMarks(values: [0.0, 3, 6, 9, 12, 15, 18, 21]) { v in
                            AxisGridLine()
                            AxisValueLabel { if let h = v.as(Double.self) { Text(hourLabel(Int(h))) } }
                        }
                    }
                    .chartYAxisLabel("minutes")
                } else {
                    Chart(weekSlots()) { slot in
                        BarMark(x: .value("Day", dayLabel(slot.index)), y: .value("Hours", slot.seconds / 3600), width: .ratio(0.6))
                            .foregroundStyle(by: .value("Category", slot.category.rawValue))
                            .cornerRadius(3)
                    }
                    .chartXScale(domain: model.days.indices.map { dayLabel($0) })
                    .chartYAxisLabel("hours")
                }
            }
            .chartForegroundStyleScale(domain: cats.map { $0.rawValue }, range: cats.map { TimeTrackerModel.color($0) })
            .chartLegend(position: .bottom, spacing: 12)
            .frame(height: 230)
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func weekSlots() -> [TimeStats.Slot] {
        var out: [TimeStats.Slot] = []
        for (i, d) in model.days.enumerated() {
            let key = TimeStore.dayKey(d)
            let segs = model.segments.filter { TimeStore.dayKey($0.start) == key }
            for (cat, secs) in TimeStats.byCategory(segs) { out.append(TimeStats.Slot(index: i, category: cat, seconds: secs)) }
        }
        return out
    }

    private func hourLabel(_ h: Int) -> String {
        let hour = h % 12 == 0 ? 12 : h % 12
        return "\(hour)\(h < 12 ? "a" : "p")"
    }

    private func dayLabel(_ i: Int) -> String {
        let d = model.days
        guard i >= 0 && i < d.count else { return "" }
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f.string(from: d[i])
    }

    private var appsCard: some View {
        let apps = TimeStats.byApp(model.segments)
        let top = apps.first?.seconds ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text("Apps").font(.system(size: 13, weight: .semibold))
            ForEach(apps.prefix(15)) { a in
                HStack(spacing: 10) {
                    Image(nsImage: TimeTrackerModel.icon(for: a.app)).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(a.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(a.category.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Text(TimeStats.format(a.seconds)).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                        }
                        GeometryReader { g in
                            Capsule()
                                .fill(TimeTrackerModel.color(a.category))
                                .frame(width: max(4, g.size.width * a.seconds / top), height: 5)
                        }
                        .frame(height: 5)
                    }
                }
            }
            if apps.count > 15 {
                Text("and \(apps.count - 15) more").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
