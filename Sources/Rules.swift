// Dandelion - Folder Rules engine (no UI here, so it can be tested on its own).
//
// A rule watches one folder: "if a file matches these conditions, do this with it."
// Only the folder's own items are looked at (not everything inside its subfolders), like Hazel.
// Rules never overwrite anything (a clash gets a new name), skip files that are still downloading
// or were changed in the last few seconds, and every run can be undone.
//
// MIT License. See LICENSE.

import Darwin
import Foundation

enum FileKind: String, Codable, CaseIterable, Identifiable {
    case image = "Image", video = "Video", audio = "Audio", document = "Document", archive = "Archive"
    case installer = "Installer", screenshot = "Screenshot", code = "Code", other = "Other"
    var id: String { rawValue }

    static func of(name: String) -> FileKind {
        let lower = name.lowercased()
        if (lower.hasPrefix("screenshot ") || lower.hasPrefix("screen shot ") || lower.hasPrefix("cleanshot "))
            && (lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".heic")) { return .screenshot }
        if lower.hasPrefix("screen recording ") && (lower.hasSuffix(".mov") || lower.hasSuffix(".mp4")) { return .screenshot }
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "raw", "cr2", "cr3", "nef", "arw", "dng", "svg", "psd":
            return .image
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "mts", "m2ts", "mxf", "3gp":
            return .video
        case "mp3", "m4a", "wav", "aif", "aiff", "flac", "aac", "ogg", "opus", "caf":
            return .audio
        case "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key", "epub", "odt":
            return .document
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst":
            return .archive
        case "dmg", "pkg", "mpkg", "iso", "app":
            return .installer
        case "swift", "py", "js", "ts", "html", "css", "json", "c", "cpp", "h", "m", "rs", "go", "java", "sh", "rb", "php", "yml", "yaml":
            return .code
        default:
            return .other
        }
    }

    /// Folder name used when sorting by type.
    var folderName: String {
        switch self {
        case .image: return "Images"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .document: return "Documents"
        case .archive: return "Archives"
        case .installer: return "Installers"
        case .screenshot: return "Screenshots"
        case .code: return "Code"
        case .other: return "Other"
        }
    }
}

struct RuleCondition: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case kindIs = "Kind is"
        case nameContains = "Name contains"
        case extensionIs = "Extension is"
        case addedMoreThanDaysAgo = "Added more than (days) ago"
        case modifiedMoreThanDaysAgo = "Modified more than (days) ago"
        case largerThanMB = "Larger than (MB)"
        case smallerThanMB = "Smaller than (MB)"
        var id: String { rawValue }
        var usesNumber: Bool { [.addedMoreThanDaysAgo, .modifiedMoreThanDaysAgo, .largerThanMB, .smallerThanMB].contains(self) }
    }

    var id = UUID()
    var kind: Kind
    var text: String = ""
    var number: Double = 7
    var fileKind: FileKind = .installer
}

struct RuleAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case moveTo = "Move to folder"
        case sortByType = "Sort into folders by type"
        case sortByMonth = "Sort into folders by month"
        case moveToTrash = "Move to the Trash"
        var id: String { rawValue }
    }

    var kind: Kind
    /// Where things go (for "Move to folder"); for the sort actions, where the type/month folders are made.
    /// Empty means "inside the watched folder".
    var destination: String = ""
}

struct FolderRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var enabled = true
    var folder: String
    var matchAll = true
    var conditions: [RuleCondition]
    var action: RuleAction
}

/// One file the rule would act on, and where it would go (nil destination = the Trash).
struct PlannedMove: Identifiable, Equatable {
    var id: String { source }
    let source: String
    let destination: String?
    let fileID: UInt64
    let ruleName: String
}

/// What happened in a run, so it can be undone.
struct RuleLogEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    let date: Date
    let ruleName: String
    let from: String
    /// Where it ended up (for the Trash, its spot in the Trash).
    let to: String
    let toTrash: Bool
}

struct RuleRun {
    var done: [RuleLogEntry] = []
    var problems: [String] = []
}

enum RulesEngine {
    /// Names browsers and download tools use while a file is still arriving.
    static let unfinished: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp", "aria2"]

    /// What a rule would do right now, without touching anything.
    static func plan(_ rule: FolderRule, now: Date = Date()) -> [PlannedMove] {
        guard rule.enabled, !rule.conditions.isEmpty || rule.action.kind != .moveToTrash else { return [] }
        let folder = (rule.folder as NSString).standardizingPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var out: [PlannedMove] = []
        for name in names.sorted() {
            if name.hasPrefix(".") { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            if unfinished.contains(ext) { continue }
            let path = (folder as NSString).appendingPathComponent(name)
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let type = Int(st.st_mode) & 0o170000
            let isFile = type == 0o100000
            let isPackage = type == 0o040000 && !ext.isEmpty && DuplicateFinder.packages.contains(ext)
            guard isFile || isPackage else { continue }   // plain files (and app-style packages) only, never folders or links
            let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) < 10 { continue }   // still being written
            let url = URL(fileURLWithPath: path)
            let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate) ?? modified
            let length = Int64(st.st_size)
            let info = FileInfo(name: name, ext: ext, kind: FileKind.of(name: name), added: added, modified: modified, length: length)
            guard matches(rule, info, now: now) else { continue }
            let dest = destination(for: rule, info: info, folder: folder)
            if let d = dest, d == path { continue }   // already where it belongs
            out.append(PlannedMove(source: path, destination: dest, fileID: UInt64(st.st_ino), ruleName: rule.name))
        }
        return out
    }

    struct FileInfo {
        let name: String
        let ext: String
        let kind: FileKind
        let added: Date
        let modified: Date
        let length: Int64
    }

    static func matches(_ rule: FolderRule, _ f: FileInfo, now: Date) -> Bool {
        if rule.conditions.isEmpty { return true }
        let results = rule.conditions.map { c -> Bool in
            switch c.kind {
            case .kindIs: return f.kind == c.fileKind
            case .nameContains:
                let t = c.text.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && f.name.localizedCaseInsensitiveContains(t)
            case .extensionIs:
                let wanted = c.text.lowercased().split(whereSeparator: { $0 == "," || $0 == " " })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
                return wanted.contains(f.ext)
            case .addedMoreThanDaysAgo: return now.timeIntervalSince(f.added) > c.number * 86400
            case .modifiedMoreThanDaysAgo: return now.timeIntervalSince(f.modified) > c.number * 86400
            case .largerThanMB: return Double(f.length) > c.number * 1_000_000
            case .smallerThanMB: return Double(f.length) < c.number * 1_000_000
            }
        }
        return rule.matchAll ? results.allSatisfy { $0 } : results.contains(true)
    }

    /// Where a matching file goes. nil means the Trash.
    static func destination(for rule: FolderRule, info: FileInfo, folder: String) -> String? {
        let base = rule.action.destination.isEmpty ? folder : (rule.action.destination as NSString).standardizingPath
        switch rule.action.kind {
        case .moveTo:
            return (base as NSString).appendingPathComponent(info.name)
        case .sortByType:
            return ((base as NSString).appendingPathComponent(info.kind.folderName) as NSString).appendingPathComponent(info.name)
        case .sortByMonth:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM"
            return ((base as NSString).appendingPathComponent(f.string(from: info.added)) as NSString).appendingPathComponent(info.name)
        case .moveToTrash:
            return nil
        }
    }

    /// Why a rule isn't safe to run, or nil if it's fine.
    static func problem(with rule: FolderRule) -> String? {
        let folder = (rule.folder as NSString).standardizingPath
        var isDir: ObjCBool = false
        if folder.isEmpty || !FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) || !isDir.boolValue {
            return "Choose a folder for \u{201C}\(rule.name)\u{201D} to watch."
        }
        let logical = Safety.logicalPath(DisplayName.realPath(folder) ?? folder)
        let blocked = ["/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin", "/sbin", "/private", "/Volumes", "/opt"]
        if blocked.contains(logical) || logical.hasPrefix("/System/") || logical.hasPrefix("/usr/") || logical.hasPrefix("/Library/")
            || logical == Safety.logicalPath(NSHomeDirectory()) || logical == Safety.logicalPath(NSHomeDirectory()) + "/Library"
            || logical.hasPrefix(Safety.logicalPath(NSHomeDirectory()) + "/Library/") {
            return "Rules can't run on \u{201C}\((folder as NSString).lastPathComponent)\u{201D}: macOS keeps important files there."
        }
        if rule.action.kind == .moveTo && rule.action.destination.isEmpty {
            return "Pick where \u{201C}\(rule.name)\u{201D} should move files to."
        }
        if rule.action.kind != .moveToTrash && !rule.action.destination.isEmpty {
            let d = Safety.logicalPath(DisplayName.realPath(rule.action.destination) ?? rule.action.destination)
            let systemSpots = ["/System", "/usr/", "/Library/", "/bin", "/sbin", "/private/etc", "/private/var/db", "/private/var/vm"]
            if d == "/" || systemSpots.contains(where: { d.hasPrefix($0) }) {
                return "\u{201C}\(rule.name)\u{201D} can't move files into a system folder."
            }
        }
        if rule.action.kind == .moveToTrash && rule.conditions.isEmpty {
            return "\u{201C}\(rule.name)\u{201D} would trash everything in the folder. Add at least one condition."
        }
        return nil
    }

    /// Carries out a plan. Each file is checked again first (still there, still the same file, not being written),
    /// and nothing is ever overwritten.
    static func run(_ moves: [PlannedMove], now: Date = Date()) -> RuleRun {
        var result = RuleRun()
        let fm = FileManager.default
        for m in moves {
            var st = stat()
            guard lstat(m.source, &st) == 0, UInt64(st.st_ino) == m.fileID else {
                result.problems.append("\((m.source as NSString).lastPathComponent) changed or moved before it could be handled.")
                continue
            }
            if let dest = m.destination {
                let dir = (dest as NSString).deletingLastPathComponent
                do {
                    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let target = uniquePath(dest)
                    try fm.moveItem(atPath: m.source, toPath: target)
                    result.done.append(RuleLogEntry(date: now, ruleName: m.ruleName, from: m.source, to: target, toTrash: false))
                } catch {
                    result.problems.append("\((m.source as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            } else {
                if let reason = Safety.protectionReason(path: m.source, title: (m.source as NSString).lastPathComponent) {
                    result.problems.append(reason)
                    continue
                }
                do {
                    var out: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: m.source), resultingItemURL: &out)
                    result.done.append(RuleLogEntry(date: now, ruleName: m.ruleName, from: m.source,
                                                    to: (out as URL?)?.path ?? "", toTrash: true))
                } catch {
                    result.problems.append("\((m.source as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return result
    }

    /// Puts files back where they were (newest first). Returns problems, if any.
    static func undo(_ entries: [RuleLogEntry]) -> [String] {
        var problems: [String] = []
        let fm = FileManager.default
        for e in entries.reversed() where !e.to.isEmpty {
            guard fm.fileExists(atPath: e.to) else {
                problems.append("\((e.from as NSString).lastPathComponent) isn't where it was moved to anymore.")
                continue
            }
            do {
                try fm.createDirectory(atPath: (e.from as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: e.to, toPath: uniquePath(e.from))
            } catch {
                problems.append("\((e.from as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        return problems
    }

    /// "name.ext", or "name 2.ext", "name 3.ext"... whichever is free.
    static func uniquePath(_ path: String) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) && (try? fm.destinationOfSymbolicLink(atPath: path)) == nil { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = (dir as NSString).appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate) && (try? fm.destinationOfSymbolicLink(atPath: candidate)) == nil { return candidate }
            n += 1
        }
    }

    // MARK: saving rules

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Dandelion", isDirectory: true).appendingPathComponent("rules.json")
    }

    static func load(from url: URL = storeURL) -> [FolderRule] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FolderRule].self, from: data)) ?? []
    }

    /// Written atomically (never half-saved) and readable only by you.
    static func save(_ rules: [FolderRule], to url: URL = storeURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rules).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    // MARK: ready-made rules

    static func templates(home: String = NSHomeDirectory()) -> [FolderRule] {
        [
            FolderRule(name: "Clear out old installers", folder: home + "/Downloads",
                       conditions: [RuleCondition(kind: .kindIs, fileKind: .installer),
                                    RuleCondition(kind: .addedMoreThanDaysAgo, number: 7)],
                       action: RuleAction(kind: .moveToTrash)),
            FolderRule(name: "Sort Downloads by type", folder: home + "/Downloads",
                       conditions: [RuleCondition(kind: .addedMoreThanDaysAgo, number: 1)],
                       action: RuleAction(kind: .sortByType)),
            FolderRule(name: "Tidy screenshots off the Desktop", folder: home + "/Desktop",
                       conditions: [RuleCondition(kind: .kindIs, fileKind: .screenshot),
                                    RuleCondition(kind: .addedMoreThanDaysAgo, number: 3)],
                       action: RuleAction(kind: .moveTo, destination: home + "/Pictures/Screenshots")),
        ]
    }
}
