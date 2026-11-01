// Dandelion - a free and open-source disk space visualizer for macOS.
// MIT License. See LICENSE.

import AppKit
import Foundation

/// One file or folder in the scanned tree.
/// Sizes are *allocated* sizes (blocks on disk), like Finder's "on disk" and DaisyDisk.
final class Node: Identifiable, Hashable {
    let name: String
    /// Total allocated bytes of this item (and everything inside it, for folders).
    var size: Int64
    /// Bytes used by the item itself (the folder entry, or the file).
    var ownSize: Int64
    let isDir: Bool
    weak var parent: Node?
    /// Children, biggest first (sorted once the folder has been scanned).
    var children: [Node] = []
    /// Number of files inside (1 for a file).
    var fileCount: Int
    /// Name to show instead of `name` (used for the root: a disk name instead of a path).
    var displayName: String?
    /// "Hidden space": not a real file, can't be revealed or deleted.
    var isSynthetic = false
    /// A folder we weren't allowed to look inside.
    var unreadable = false
    /// Internal: created while splitting the scan into parallel jobs.
    var splitNode = false

    init(name: String, isDir: Bool, size: Int64) {
        self.name = name
        self.isDir = isDir
        self.size = size
        self.ownSize = size
        self.fileCount = isDir ? 0 : 1
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    static func == (a: Node, b: Node) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    var title: String { displayName ?? name }
    var isRoot: Bool { parent == nil }

    /// Full path on disk. The root's `name` is its full path.
    var path: String {
        guard let parent = parent else { return name }
        let pp = parent.path
        return pp.hasSuffix("/") ? pp + name : pp + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isDir) }

    /// Root first, self last.
    var ancestry: [Node] {
        var list: [Node] = []
        var cur: Node? = self
        while let n = cur { list.append(n); cur = n.parent }
        return list.reversed()
    }

    var canTouch: Bool { !isSynthetic && !isRoot }

    func add(_ child: Node) {
        child.parent = self
        children.append(child)
    }

    /// Adds up the children (call once every child is final) and sorts them biggest first.
    func finalize() {
        var total = ownSize
        var files = isDir ? 0 : 1
        for c in children {
            total += c.size
            files += c.fileCount
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
        p.children.removeAll { $0 === self }
        var cur: Node? = p
        while let n = cur {
            n.size -= size
            n.fileCount -= fileCount
            cur = n.parent
        }
        parent = nil
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
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: mountURL.path) }

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
                                  total: total, free: free, isStartup: isRoot,
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
    static func items(_ n: Int) -> String {
        n == 1 ? "1 file" : count(n) + " files"
    }
    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

// The tree is built on a background thread, then handed to the main thread and only touched there.
extension Node: @unchecked Sendable {}
