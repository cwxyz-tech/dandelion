// Dandelion - the disk scanner.
// Walks the disk with fts (the same fast C walker `du` uses), split into many parallel jobs.
// MIT License. See LICENSE.

import Darwin
import Foundation

/// Live counters the UI reads while a scan runs. Thread-safe.
final class ScanProgress: @unchecked Sendable {
    struct Snapshot {
        var files = 0
        var bytes: Int64 = 0
        var skipped = 0
        var path = ""
    }

    private let lock = NSLock()
    private var snap = Snapshot()
    private var stop = false

    func add(files: Int, bytes: Int64, path: String?) {
        lock.lock()
        snap.files += files
        snap.bytes += bytes
        if let path = path { snap.path = path }
        lock.unlock()
    }

    func skipped() {
        lock.lock(); snap.skipped += 1; lock.unlock()
    }

    func cancel() {
        lock.lock(); stop = true; lock.unlock()
    }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stop
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snap
    }
}

/// Hard-linked files are only counted once (Time Machine and Xcode use lots of them).
private final class InodeSet: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<UInt64>()

    /// True the first time an inode is seen.
    func insert(_ ino: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(ino).inserted
    }
}

enum Scanner {
    private struct Job {
        let parent: Node
        let path: String
    }

    /// Scans everything under `path` that's on the same disk. Runs on a background thread; blocks until done or cancelled.
    static func scan(path: String, title: String, progress: ScanProgress) -> Node {
        let root = Node(name: path, isDir: true, size: 0)
        root.displayName = title
        var st = stat()
        guard lstat(path, &st) == 0 else {
            root.unreadable = true
            return root
        }
        let dev = st.st_dev
        let seen = InodeSet()

        // The top two levels are listed here, and every folder below them becomes its own job,
        // so the work spreads across all CPU cores even when one folder (like ~/Library) is huge.
        var jobs: [Job] = []
        split(root, path: path, dev: dev, level: 0, jobs: &jobs, seen: seen, progress: progress)

        var results = [Node?](repeating: nil, count: jobs.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let node = walk(jobs[i].path, dev: dev, seen: seen, progress: progress)
            resultsLock.lock()
            results[i] = node
            resultsLock.unlock()
        }
        for (i, job) in jobs.enumerated() {
            if let n = results[i] { job.parent.add(n) }
        }
        finishSplit(root)
        return root
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.hasSuffix("/") ? a + b : a + "/" + b
    }

    private static func allocated(_ st: stat, seen: InodeSet) -> Int64 {
        if st.st_nlink > 1 && !seen.insert(UInt64(st.st_ino)) { return 0 }
        return Int64(st.st_blocks) * 512
    }

    private static func isDirectory(_ st: stat) -> Bool {
        (Int(st.st_mode) & 0o170000) == 0o040000   // S_IFMT / S_IFDIR
    }

    private static func split(_ node: Node, path: String, dev: dev_t, level: Int,
                              jobs: inout [Job], seen: InodeSet, progress: ScanProgress) {
        node.splitNode = true
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            node.unreadable = true
            progress.skipped()
            return
        }
        var st = stat()
        var files = 0
        var bytes: Int64 = 0
        for name in names {
            let full = join(path, name)
            guard lstat(full, &st) == 0 else { progress.skipped(); continue }
            if isDirectory(st) {
                if st.st_dev != dev { continue }   // another disk is mounted here: not part of this one
                if level < 1 {
                    let child = Node(name: name, isDir: true, size: Int64(st.st_blocks) * 512)
                    node.add(child)
                    split(child, path: full, dev: dev, level: level + 1, jobs: &jobs, seen: seen, progress: progress)
                } else {
                    jobs.append(Job(parent: node, path: full))
                }
            } else {
                let size = allocated(st, seen: seen)
                node.add(Node(name: name, isDir: false, size: size))
                files += 1
                bytes += size
            }
        }
        progress.add(files: files, bytes: bytes, path: path)
    }

    private static func finishSplit(_ node: Node) {
        for c in node.children where c.splitNode { finishSplit(c) }
        node.finalize()
    }

    /// The name part of an fts entry (fts_name is a C flexible array, so it's read from the end of fts_path).
    private static func entryName(_ ent: UnsafeMutablePointer<FTSENT>) -> String {
        guard let p = ent.pointee.fts_path else { return "?" }
        let offset = max(0, Int(ent.pointee.fts_pathlen) - Int(ent.pointee.fts_namelen))
        return String(cString: p + offset)
    }

    /// Walks one folder completely and returns it as a finished subtree.
    private static func walk(_ path: String, dev: dev_t, seen: InodeSet, progress: ScanProgress) -> Node? {
        guard let cpath = strdup(path) else { return nil }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            progress.skipped()
            return nil
        }
        defer { fts_close(fts) }

        var stack: [Node] = []
        var top: Node?
        var files = 0
        var bytes: Int64 = 0
        var tick = 0

        while let ent = fts_read(fts) {
            tick += 1
            if tick & 2047 == 0 {
                let here: String? = ent.pointee.fts_path.map { String(cString: $0) }
                progress.add(files: files, bytes: bytes, path: here)
                files = 0
                bytes = 0
                if progress.cancelled { break }
            }
            let info = Int32(ent.pointee.fts_info)
            let statp: UnsafeMutablePointer<stat>? = ent.pointee.fts_statp
            switch info {
            case FTS_D, FTS_DNR:
                let name = ent.pointee.fts_level == 0 ? (path as NSString).lastPathComponent : entryName(ent)
                let own: Int64 = statp.map { Int64($0.pointee.st_blocks) * 512 } ?? 0
                let n = Node(name: name, isDir: true, size: own)
                if let parent = stack.last { parent.add(n) } else { top = n }
                if info == FTS_D {
                    stack.append(n)
                } else {
                    // couldn't open this folder (no permission): it stays, as an empty folder
                    n.unreadable = true
                    n.finalize()
                    progress.skipped()
                }
            case FTS_DP:
                if let n = stack.popLast() { n.finalize() }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let s = statp, let parent = stack.last else { continue }
                let size = allocated(s.pointee, seen: seen)
                parent.add(Node(name: entryName(ent), isDir: false, size: size))
                files += 1
                bytes += size
            case FTS_NS, FTS_ERR:
                progress.skipped()
            default:
                break   // FTS_DC (a loop), FTS_DOT: nothing to count
            }
        }
        // cancelled part way: close up whatever is still open
        while let n = stack.popLast() { n.finalize() }
        progress.add(files: files, bytes: bytes, path: nil)
        return top
    }
}
