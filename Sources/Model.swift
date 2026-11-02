// Dandelion - the scanned file tree, the list of disks, and formatting.
// Foundation only (no AppKit), so the scanner and its test can be built on their own.
// MIT License. See LICENSE.

import Darwin
import Foundation

/// One file or folder in the scanned tree. Kept small on purpose: a full disk can hold millions of these.
/// Sizes are *allocated* sizes (space actually used on disk), like Finder's "on disk" and DaisyDisk.
class Node: Identifiable, Hashable {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let directory  = Flags(rawValue: 1 << 0)
        /// "Hidden space": not a real file, can't be revealed or deleted.
        static let synthetic  = Flags(rawValue: 1 << 1)
        /// A folder we weren't allowed to look inside.
        static let unreadable = Flags(rawValue: 1 << 2)
        /// Internal: created while splitting the scan into parallel jobs.
        static let split      = Flags(rawValue: 1 << 3)
        /// Internal: another disk is mounted here, so it's not part of this one (dropped when finalized).
        static let excluded   = Flags(rawValue: 1 << 4)
    }

    let name: String
    /// Total allocated bytes of this item (and everything inside it, for folders).
    var size: Int64
    weak var parent: Node?
    /// Children, biggest first (sorted when the folder is finalized).
    var children: [Node] = []
    /// The file's ID on disk (inode). Used to make sure an item is still the same one before it goes to the Trash.
    let fileID: UInt64
    /// Number of files inside (1 for a file).
    var fileCount: Int32
    var flags: Flags

    init(name: String, size: Int64, fileID: UInt64, flags: Flags) {
        self.name = name
        self.size = size
        self.fileID = fileID
        self.flags = flags
        self.fileCount = flags.contains(.directory) || flags.contains(.synthetic) ? 0 : 1
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    static func == (a: Node, b: Node) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    var isDir: Bool { flags.contains(.directory) }
    var isSynthetic: Bool { flags.contains(.synthetic) }
    var unreadable: Bool { flags.contains(.unreadable) }
    var isRoot: Bool { parent == nil }
    var canTouch: Bool { !isSynthetic && !isRoot }

    /// What to show for this item. File names can contain invisible or direction-flipping characters
    /// (used to disguise "photo\u{202E}gpj.app" as "photoppa.jpg"), so those are made visible.
    var title: String { DisplayName.clean(name) }

    /// Full path on disk. The root's `name` is its full path.
    var path: String {
        var parts: [String] = []
        var cur: Node? = self
        while let n = cur, let p = n.parent {
            parts.append(n.name)
            cur = p
        }
        var out = cur?.name ?? ""
        for part in parts.reversed() {
            if !out.hasSuffix("/") { out += "/" }
            out += part
        }
        return out
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isDir) }

    /// Root first, self last.
    var ancestry: [Node] {
        var list: [Node] = []
        var cur: Node? = self
        while let n = cur { list.append(n); cur = n.parent }
        return list.reversed()
    }

    var depth: Int {
        var d = 0
        var cur = parent
        while let n = cur { d += 1; cur = n.parent }
        return d
    }

    func add(_ child: Node) {
        child.parent = self
        children.append(child)
    }

    /// Adds up the children (call once every child is final) and sorts them biggest first.
    func finalize() {
        if children.contains(where: { $0.flags.contains(.excluded) }) {
            children.removeAll { $0.flags.contains(.excluded) }
        }
        var total: Int64 = 0
        var files: Int32 = 0
        for c in children {
            total += c.size
            files &+= c.fileCount
        }
        size = total
        fileCount = files
        if children.count > 1 { children.sort { $0.size > $1.size } }
    }

    func isAncestor(of other: Node) -> Bool {
        var cur: Node? = other
        while let n = cur {
            if n === self { return true }
            cur = n.parent
        }
        return false
    }

    /// Takes this item out of the tree (after it went to the Trash) and fixes every folder's total above it.
    func removeFromTree() {
        guard let p = parent else { return }
        if let i = p.children.firstIndex(where: { $0 === self }) { p.children.remove(at: i) }
        var cur: Node? = p
        while let n = cur {
            n.size -= size
            n.fileCount &-= fileCount
            cur = n.parent
        }
        parent = nil
    }
}

/// The top of a scan. Only the root carries a display name (a disk name like "Macintosh HD"),
/// and the resolved real path of the scanned folder, which the Trash safety checks compare against.
final class RootNode: Node {
    let displayName: String
    let realPath: String
    /// How long the scan took.
    var scanSeconds: Double = 0
    /// Items the scan couldn't read.
    var skipped = 0

    init(path: String, displayName: String, fileID: UInt64) {
        self.displayName = displayName
        self.realPath = DisplayName.realPath(path) ?? path
        super.init(name: path, size: 0, fileID: fileID, flags: [.directory])
    }

    override var title: String { DisplayName.clean(displayName) }
}

enum DisplayName {
    /// Replaces control characters and invisible formatting characters (bidi overrides, zero-width marks)
    /// with a visible marker, so a file can't pretend to be something else in the list.
    static func clean(_ s: String) -> String {
        // fast path: plain printable ASCII, which is almost every file name
        if s.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
                out.append("\u{FFFD}")
            default:
                out.append(u)
            }
        }
        return String(out)
    }

    /// The real path of something on disk (links resolved), or nil if it doesn't exist.
    static func realPath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}

/// A mounted disk you can scan.
struct VolumeInfo: Identifiable {
    let id = UUID()
    let name: String
    let mountURL: URL
    /// What actually gets scanned. For the startup disk that's the Data volume,
    /// which is where all your files live (the system volume is sealed and read-only).
    let scanPath: String
    let total: Int64
    /// Free space as Finder shows it (includes purgeable space).
    let free: Int64
    let isStartup: Bool
    let isInternal: Bool

    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }

    static func list() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        var out: [VolumeInfo] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.volumeIsBrowsable == false { continue }
            let isRoot = v.volumeIsRootFileSystem ?? (u.path == "/")
            let dataVolume = "/System/Volumes/Data"
            let scan = (isRoot && FileManager.default.fileExists(atPath: dataVolume)) ? dataVolume : u.path
            let total = Int64(v.volumeTotalCapacity ?? 0)
            if total <= 0 { continue }
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            out.append(VolumeInfo(name: v.volumeName ?? u.lastPathComponent, mountURL: u, scanPath: scan,
                                  total: total, free: max(0, free), isStartup: isRoot,
                                  isInternal: v.volumeIsInternal ?? false))
        }
        return out.sorted { a, b in
            if a.isStartup != b.isStartup { return a.isStartup }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }
    static func count(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
    static func items(_ n: Int32) -> String {
        n == 1 ? "1 file" : count(Int(n)) + " files"
    }
    static func duration(_ t: Double) -> String {
        if t < 10 { return String(format: "%.1fs", t) }
        let s = Int(t)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

// The tree is built on background threads, then handed to the main thread and only changed there.
extension Node: @unchecked Sendable {}
