// Dandelion - Duplicate Finder engine (no UI here, so it can be tested on its own).
//
// How it finds duplicates, cheapest step first:
//   1. Walk the chosen folders (same fast reader as the disk scan) and keep plain files above a size.
//   2. Files can only match if they're exactly the same length, so group by length and drop the loners.
//   3. Fingerprint the first 64 KB of each remaining file (SHA-256) and regroup.
//   4. Hash the whole file (SHA-256) for whatever's still grouped. Same full hash = same contents.
// Hashing runs in parallel. Hard links are one file, not duplicates, so they're only counted once.
// App bundles, photo libraries and similar packages are never opened up: deleting a file from inside
// one would break it.
//
// MIT License. See LICENSE.

import CryptoKit
import Darwin
import Foundation

struct DupFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let length: Int64
    /// Space used on disk.
    let size: Int64
    let fileID: UInt64
    var modified: Date = .distantPast

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

struct DupGroup: Identifiable {
    let id = UUID()
    var files: [DupFile]
    let length: Int64
    let hash: String

    /// Space you'd get back by keeping just one copy.
    var reclaimable: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

/// Live counters for the UI. Thread-safe.
final class DupProgress: @unchecked Sendable {
    struct Snapshot {
        var stage = "Looking for files"
        var files = 0
        var candidates = 0
        var hashedBytes: Int64 = 0
        var bytesToHash: Int64 = 0
    }

    private let lock = NSLock()
    private var snap = Snapshot()
    private var stop = false

    func update(_ change: (inout Snapshot) -> Void) {
        lock.lock(); change(&snap); lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snap
    }

    func cancel() { lock.lock(); stop = true; lock.unlock() }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stop
    }
}

enum DuplicateFinder {
    struct Options {
        /// Files smaller than this are ignored (tiny files rarely matter and are slow to compare in bulk).
        var minimumLength: Int64 = 100 * 1024
        var includeHidden = false
    }

    /// Folders that macOS treats as a single item. Never looked inside.
    static let packages: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "pkg", "mpkg", "prefpane", "saver", "qlgenerator",
        "photoslibrary", "photolibrary", "fcpbundle", "logicx", "band", "imovielibrary", "musiclibrary", "tvlibrary",
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "rtfd", "pages", "numbers", "key", "sparsebundle",
        "lrlibrary", "lrdata", "aplibrary", "photosmigrator", "docarchive", "abbu", "mbox", "nib", "storyboardc",
    ]

    private static let headBytes = 64 * 1024

    static func find(in roots: [String], options: Options = Options(), progress: DupProgress) -> [DupGroup] {
        // 1. walk
        var all: [DupFile] = []
        var seenIDs = Set<String>()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        defer { buf.deallocate() }
        var entries: [Scanner.Entry] = []
        for root in roots {
            let real = DisplayName.realPath(root) ?? root
            var rst = stat()
            guard lstat(real, &rst) == 0 else { continue }
            var stack = [real]
            var dirs = 0
            while let dir = stack.popLast() {
                dirs += 1
                if dirs & 63 == 0 && progress.cancelled { return [] }
                let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 { continue }
                var dst = stat()
                let sameDisk = fstat(fd, &dst) == 0 && dst.st_dev == rst.st_dev
                let ok = sameDisk && Scanner.readEntries(fd: fd, buf: buf, into: &entries)
                close(fd)
                if !ok { continue }
                var found = 0
                for e in entries {
                    if !options.includeHidden && e.name.hasPrefix(".") { continue }
                    let path = dir.hasSuffix("/") ? dir + e.name : dir + "/" + e.name
                    if e.isDir {
                        if e.isMountPoint { continue }
                        let ext = (e.name as NSString).pathExtension.lowercased()
                        if !ext.isEmpty && packages.contains(ext) { continue }
                        stack.append(path)
                    } else if e.isFile {
                        found += 1
                        guard e.length >= max(1, options.minimumLength) else { continue }
                        // hard links (and overlapping folders) are the same file: count it once
                        let key = "\(e.dev):\(e.fileID)"
                        if e.fileID != 0 && !seenIDs.insert(key).inserted { continue }
                        all.append(DupFile(path: path, length: e.length, size: e.size, fileID: e.fileID))
                    }
                }
                let n = found
                progress.update { $0.files += n }
            }
        }

        // 2. same length
        var byLength: [Int64: [DupFile]] = [:]
        for f in all { byLength[f.length, default: []].append(f) }
        var groups = byLength.values.filter { $0.count > 1 }
        let candidates = groups.reduce(0) { $0 + $1.count }
        let headTotal = groups.reduce(Int64(0)) { t, g in t + Int64(g.count) * min(g[0].length, Int64(headBytes)) }
        progress.update { $0.stage = "Comparing files"; $0.candidates = candidates; $0.bytesToHash = headTotal; $0.hashedBytes = 0 }
        if progress.cancelled { return [] }

        // 3. first 64 KB
        groups = regroup(groups, progress: progress) { f in hash(f.path, limit: headBytes, progress: progress) }
        if progress.cancelled { return [] }

        // 4. whole file (only where the first 64 KB didn't already cover it)
        let fullTotal = groups.reduce(Int64(0)) { t, g in g[0].length > Int64(headBytes) ? t + Int64(g.count) * g[0].length : t }
        progress.update { $0.stage = "Checking contents"; $0.bytesToHash = fullTotal; $0.hashedBytes = 0 }
        var results: [DupGroup] = []
        var needFull: [[DupFile]] = []
        for g in groups {
            if g[0].length <= Int64(headBytes) {
                results.append(DupGroup(files: g, length: g[0].length, hash: ""))
            } else {
                needFull.append(g)
            }
        }
        var fullHashes: [String: String] = [:]
        let regrouped = regroup(needFull, progress: progress) { f in
            hash(f.path, limit: nil, progress: progress)
        } onHash: { path, h in fullHashes[path] = h }
        if progress.cancelled { return [] }
        for g in regrouped { results.append(DupGroup(files: g, length: g[0].length, hash: fullHashes[g[0].path] ?? "")) }

        // dates for the keep rules, then biggest wins first
        results = results.map { g in
            var g = g
            g.files = g.files.map { f in
                var f = f
                var st = stat()
                if lstat(f.path, &st) == 0 {
                    f.modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
                }
                return f
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return g
        }
        return results.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// Splits each group by a per-file key computed in parallel. Files whose key fails (unreadable) drop out.
    private static func regroup(_ groups: [[DupFile]], progress: DupProgress, key: (DupFile) -> String?,
                                onHash: ((String, String) -> Void)? = nil) -> [[DupFile]] {
        let files = groups.flatMap { $0 }
        if files.isEmpty { return [] }
        var keys = [String?](repeating: nil, count: files.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            if progress.cancelled { return }
            let k = key(files[i])
            lock.lock(); keys[i] = k; lock.unlock()
        }
        var index = 0
        var out: [[DupFile]] = []
        for g in groups {
            var sub: [String: [DupFile]] = [:]
            for f in g {
                if let k = keys[index] {
                    sub["\(f.length):\(k)", default: []].append(f)
                    onHash?(f.path, k)
                }
                index += 1
            }
            out.append(contentsOf: sub.values.filter { $0.count > 1 })
        }
        return out
    }

    /// SHA-256 of a file (or its first `limit` bytes). Opened without following links, read without filling the cache.
    static func hash(_ path: String, limit: Int?, progress: DupProgress?) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var remaining = limit ?? Int.max
        var sinceReport = 0
        while remaining > 0 {
            let n = read(fd, buffer, min(chunk, remaining))
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            remaining -= n
            sinceReport += n
            if sinceReport >= 8 << 20 {
                let r = sinceReport
                progress?.update { $0.hashedBytes += Int64(r) }
                sinceReport = 0
                if progress?.cancelled == true { return nil }
            }
        }
        let r = sinceReport
        progress?.update { $0.hashedBytes += Int64(r) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: choosing what to keep

    enum KeepRule: String, CaseIterable, Identifiable {
        case oldest = "Keep the oldest"
        case newest = "Keep the newest"
        case shortestPath = "Keep the one nearest the top"
        var id: String { rawValue }
    }

    /// The copy to keep in a group under a rule. Everything else gets selected.
    static func keeper(_ g: DupGroup, rule: KeepRule) -> DupFile? {
        switch rule {
        case .oldest: return g.files.min { $0.modified < $1.modified }
        case .newest: return g.files.max { $0.modified < $1.modified }
        case .shortestPath:
            return g.files.min { a, b in
                let da = a.path.split(separator: "/").count, db = b.path.split(separator: "/").count
                return da != db ? da < db : a.path.count < b.path.count
            }
        }
    }

    /// Checks a file is exactly what was found (same file, same length, not edited since) right before it's moved.
    static func verify(_ f: DupFile) -> String? {
        var st = stat()
        guard lstat(f.path, &st) == 0 else { return "\u{201C}\(DisplayName.clean(f.name))\u{201D} isn't there anymore." }
        let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        if UInt64(st.st_ino) != f.fileID || Int64(st.st_size) != f.length || abs(mtime.timeIntervalSince(f.modified)) > 1 {
            return "\u{201C}\(DisplayName.clean(f.name))\u{201D} changed since it was found. Scan again, then try again."
        }
        return nil
    }
}
