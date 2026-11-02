// Dandelion - Time Tracker engine (no UI here, so it can be tested on its own).
//
// Records which app is in front, and for how long, as a list of segments: "Safari, 9:02 to 9:17".
// Only the app's name and the times are kept. No window titles, no screenshots, nothing about what you typed.
// Each day is one small JSON file in ~/Library/Application Support/Dandelion/Time, readable only by you.
//
// MIT License. See LICENSE.

import Darwin
import Foundation

struct TimeSegment: Codable, Equatable {
    /// Bundle identifier, or the app's name if it has none.
    var app: String
    var name: String
    var category: TimeCategory
    var start: Date
    var end: Date

    var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

enum TimeCategory: String, Codable, CaseIterable, Identifiable {
    case development = "Development"
    case productivity = "Productivity"
    case communication = "Communication"
    case browsing = "Browsing"
    case creative = "Creative"
    case entertainment = "Entertainment"
    case other = "Other"

    var id: String { rawValue }

    /// Works out a category from the app's bundle ID, and the category the app declares for itself
    /// (LSApplicationCategoryType in its Info.plist) when there's no better match.
    static func of(bundleID: String, declared: String?) -> TimeCategory {
        let id = bundleID.lowercased()
        let known: [(TimeCategory, [String])] = [
            (.development, ["com.apple.dt.xcode", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.jetbrains", "com.apple.terminal",
                            "com.googlecode.iterm2", "dev.warp", "com.sublimetext", "com.github.githubclient", "com.panic.nova",
                            "dev.zed", "com.mitchellh.ghostty", "com.anthropic.claudecode", "com.postmanlabs"]),
            (.communication, ["com.apple.mail", "com.apple.mobilesms", "com.apple.facetime", "com.tinyspeck.slackmacgap", "us.zoom",
                              "com.microsoft.teams", "com.hnc.discord", "net.whatsapp", "ru.keepcoder.telegram", "com.readdle.smartemail",
                              "com.microsoft.outlook", "com.superhuman", "com.facebook.archon"]),
            (.browsing, ["com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser",
                         "com.brave.browser", "com.operasoftware", "com.vivaldi", "app.zen-browser", "com.kagi.kagimacos"]),
            (.creative, ["com.adobe", "com.figma", "com.bohemiancoding.sketch3", "com.apple.finalcut", "com.apple.logic", "com.apple.garageband",
                         "com.apple.imovie", "com.blackmagic-design", "com.pixelmatorteam", "com.seriflabs", "org.blenderfoundation",
                         "com.apple.photos", "com.apple.motionapp", "com.procreate"]),
            (.entertainment, ["com.apple.music", "com.apple.tv", "com.spotify", "com.apple.podcasts", "com.netflix", "tv.twitch",
                              "com.valvesoftware.steam", "com.apple.arcade", "com.colliderli.iina", "org.videolan.vlc"]),
            (.productivity, ["com.apple.iwork", "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint", "com.apple.notes",
                             "com.apple.ical", "com.apple.reminders", "notion.id", "md.obsidian", "com.culturedcode.things",
                             "com.apple.finder", "com.apple.preview", "com.linear", "com.todoist", "com.anthropic.claudefordesktop"]),
        ]
        for (cat, prefixes) in known where prefixes.contains(where: { id.hasPrefix($0) }) { return cat }
        switch declared ?? "" {
        case "public.app-category.developer-tools": return .development
        case "public.app-category.social-networking": return .communication
        case "public.app-category.graphics-design", "public.app-category.photography", "public.app-category.video",
             "public.app-category.music": return .creative
        case "public.app-category.entertainment", "public.app-category.games", "public.app-category.action-games",
             "public.app-category.adventure-games", "public.app-category.arcade-games", "public.app-category.board-games",
             "public.app-category.card-games", "public.app-category.casino-games", "public.app-category.puzzle-games",
             "public.app-category.racing-games", "public.app-category.role-playing-games", "public.app-category.simulation-games",
             "public.app-category.sports-games", "public.app-category.strategy-games", "public.app-category.word-games",
             "public.app-category.family-games", "public.app-category.kids-games", "public.app-category.educational-games",
             "public.app-category.dice-games", "public.app-category.trivia-games", "public.app-category.music-games":
            return .entertainment
        case "public.app-category.productivity", "public.app-category.business", "public.app-category.finance",
             "public.app-category.education", "public.app-category.reference", "public.app-category.utilities":
            return .productivity
        default: return .other
        }
    }
}

/// Turns "this app came to the front" events into segments. Pure logic: feed it events and times, read segments out.
struct TimeRecorder {
    struct Current: Equatable {
        var app: String
        var name: String
        var category: TimeCategory
        var start: Date
    }

    private(set) var current: Current?
    /// Finished segments not yet handed off (split at midnight, so each belongs to one day).
    private(set) var finished: [TimeSegment] = []

    /// Segments shorter than this are dropped (a quick Command-Tab past an app isn't time spent in it).
    static let minimum: TimeInterval = 2

    /// A different app came to the front.
    mutating func switchTo(app: String, name: String, category: TimeCategory, at date: Date) {
        if let c = current, c.app == app { return }
        close(at: date)
        current = Current(app: app, name: name, category: category, start: date)
    }

    /// Stop counting (idle, asleep, locked, or paused). `date` can be in the past, to leave out the idle time.
    mutating func pause(at date: Date) {
        close(at: date)
        current = nil
    }

    /// Closes the running segment at `date` and starts the same app again from there, so a save never loses
    /// more than the time since the last flush.
    mutating func flush(at date: Date) {
        guard let c = current else { return }
        close(at: date)
        current = Current(app: c.app, name: c.name, category: c.category, start: max(date, c.start))
    }

    mutating func takeFinished() -> [TimeSegment] {
        defer { finished.removeAll() }
        return finished
    }

    private mutating func close(at date: Date) {
        guard let c = current else { return }
        let end = max(date, c.start)
        current = nil
        guard end.timeIntervalSince(c.start) >= Self.minimum else { return }
        finished += TimeRecorder.splitAtMidnight(TimeSegment(app: c.app, name: c.name, category: c.category, start: c.start, end: end))
    }

    /// One segment per calendar day it touches.
    static func splitAtMidnight(_ s: TimeSegment, calendar: Calendar = .current) -> [TimeSegment] {
        var out: [TimeSegment] = []
        var piece = s
        while true {
            let startOfNext = calendar.startOfDay(for: piece.start).addingTimeInterval(36 * 3600)
            let midnight = calendar.startOfDay(for: startOfNext)
            if piece.end <= midnight { out.append(piece); break }
            var first = piece
            first.end = midnight
            out.append(first)
            piece.start = midnight
        }
        return out.filter { $0.seconds > 0 }
    }
}

enum TimeStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Dandelion", isDirectory: true).appendingPathComponent("Time", isDirectory: true)
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func url(day: String, in folder: URL) -> URL { folder.appendingPathComponent(day + ".json") }

    static func load(day: String, from folder: URL = folder) -> [TimeSegment] {
        guard let data = try? Data(contentsOf: url(day: day, in: folder)) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([TimeSegment].self, from: data)) ?? []
    }

    /// Written atomically and readable only by you (the folder too).
    static func save(_ segments: [TimeSegment], day: String, to folder: URL = folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chmod(folder.path, 0o700)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let file = url(day: day, in: folder)
        try enc.encode(segments).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }

    /// Adds finished segments to their days' files, joining each onto the last one when it simply continues it.
    static func append(_ segments: [TimeSegment], to folder: URL = folder) throws {
        let byDay = Dictionary(grouping: segments) { dayKey($0.start) }
        for (day, new) in byDay {
            var all = load(day: day, from: folder)
            for s in new.sorted(by: { $0.start < $1.start }) {
                if var last = all.last, last.app == s.app, abs(s.start.timeIntervalSince(last.end)) < 1 {
                    last.end = max(last.end, s.end)
                    all[all.count - 1] = last
                } else {
                    all.append(s)
                }
            }
            try save(all, day: day, to: folder)
        }
    }

    static func delete(day: String, from folder: URL = folder) {
        try? FileManager.default.removeItem(at: url(day: day, in: folder))
    }

    static func deleteAll(from folder: URL = folder) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" { try? FileManager.default.removeItem(at: f) }
    }
}

enum TimeStats {
    struct AppTotal: Identifiable, Equatable {
        var id: String { app }
        let app: String
        let name: String
        let category: TimeCategory
        let seconds: TimeInterval
    }

    struct Slot: Identifiable, Equatable {
        var id: String { "\(index)-\(category.rawValue)" }
        let index: Int
        let category: TimeCategory
        let seconds: TimeInterval
    }

    static func total(_ segs: [TimeSegment]) -> TimeInterval { segs.reduce(0) { $0 + $1.seconds } }

    static func byApp(_ segs: [TimeSegment]) -> [AppTotal] {
        var totals: [String: (String, TimeCategory, TimeInterval)] = [:]
        for s in segs {
            let t = totals[s.app]
            totals[s.app] = (s.name, s.category, (t?.2 ?? 0) + s.seconds)
        }
        return totals.map { AppTotal(app: $0.key, name: $0.value.0, category: $0.value.1, seconds: $0.value.2) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
    }

    static func byCategory(_ segs: [TimeSegment]) -> [(TimeCategory, TimeInterval)] {
        var totals: [TimeCategory: TimeInterval] = [:]
        for s in segs { totals[s.category, default: 0] += s.seconds }
        return totals.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// Seconds per hour of one day (0...23) and category, splitting segments that cross an hour.
    static func byHour(_ segs: [TimeSegment], day: Date, calendar: Calendar = .current) -> [Slot] {
        let start = calendar.startOfDay(for: day)
        var bins: [Int: [TimeCategory: TimeInterval]] = [:]
        for s in segs {
            var t = max(s.start, start)
            let end = s.end
            while t < end {
                let hour = Int(t.timeIntervalSince(start) / 3600)
                guard hour >= 0 && hour < 24 else { break }
                let hourEnd = start.addingTimeInterval(Double(hour + 1) * 3600)
                let pieceEnd = min(end, hourEnd)
                bins[hour, default: [:]][s.category, default: 0] += pieceEnd.timeIntervalSince(t)
                t = pieceEnd
            }
        }
        return bins.flatMap { h, cats in cats.map { Slot(index: h, category: $0.key, seconds: $0.value) } }
            .sorted { $0.index != $1.index ? $0.index < $1.index : $0.category.rawValue < $1.category.rawValue }
    }

    /// "2h 15m", "45m", "30s".
    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let h = s / 3600, m = (s % 3600) / 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
