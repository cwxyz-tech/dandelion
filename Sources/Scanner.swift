// Dandelion - the disk scanner.
//
// Each folder is read with getattrlistbulk(2): one system call returns the names, types, IDs and
// on-disk sizes of a whole batch of entries, instead of one stat() per file. That's the fast path macOS
// itself uses. If a disk doesn't support it, that folder is read the classic way (readdir + fstatat).
//
// The work is split into many folders up front and spread across every CPU core.
// Folders are opened with O_NOFOLLOW, so a link swapped in mid-scan is never followed out of the disk.
//
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
/// Split into shards so parallel workers rarely wait on each other.
final class InodeSet: @unchecked Sendable {
    private let shards = 32
    private let locks: [NSLock]
    private var sets: [Set<UInt64>]

    init() {
        locks = (0..<32).map { _ in NSLock() }
        sets = Array(repeating: Set<UInt64>(), count: 32)
    }

    /// True the first time an ID is seen.
    func insert(_ id: UInt64) -> Bool {
        let i = Int(truncatingIfNeeded: (id ^ (id >> 17)) % UInt64(shards))
        locks[i].lock(); defer { locks[i].unlock() }
        return sets[i].insert(id).inserted
    }
}

enum Scanner {
    /// One directory entry, as read from disk.
    struct Entry {
        var name: String
        var isDir: Bool
        /// A plain file (not a link, device or anything else).
        var isFile: Bool
        var isMountPoint: Bool
        var dev: dev_t
        var fileID: UInt64
        var links: UInt32
        /// Space used on disk.
        var size: Int64
        /// The file's actual length in bytes (what duplicates are compared by).
        var length: Int64
    }

    private struct Job {
        let node: Node
        let path: String
    }

    /// The shared work queue. Workers take folders from it; when someone's idle, busy workers hand over
    /// subfolders instead of keeping them, so one giant folder can't leave the other cores waiting.
    private final class Context: @unchecked Sendable {
        let dev: dev_t
        let progress: ScanProgress
        let seen: InodeSet
        private let cond = NSCondition()
        private var queue: [Job]
        private var active = 0
        private var waiting = 0

        init(dev: dev_t, progress: ScanProgress, seen: InodeSet, jobs: [Job]) {
            self.dev = dev
            self.progress = progress
            self.seen = seen
            self.queue = jobs
        }

        /// Next folder to walk, or nil once every folder is done.
        func take() -> Job? {
            cond.lock(); defer { cond.unlock() }
            while true {
                if let job = queue.popLast() {
                    active += 1
                    return job
                }
                if active == 0 {
                    cond.broadcast()
                    return nil
                }
                waiting += 1
                cond.wait()
                waiting -= 1
            }
        }

        func finished() {
            cond.lock()
            active -= 1
            if active == 0 && queue.isEmpty { cond.broadcast() }
            cond.unlock()
        }

        /// True when another worker is waiting for something to do.
        var hungry: Bool {
            cond.lock(); defer { cond.unlock() }
            return waiting > 0 && queue.isEmpty
        }

        func share(_ jobs: ArraySlice<Job>) {
            cond.lock()
            queue.append(contentsOf: jobs)
            cond.broadcast()
            cond.unlock()
        }
    }

    // attribute bits (sys/attr.h), spelled out so their types are exact
    private enum A {
        static let cmnName: UInt32 = 0x0000_0001
        static let cmnDevID: UInt32 = 0x0000_0002
        static let cmnObjType: UInt32 = 0x0000_0008
        static let cmnFileID: UInt32 = 0x0200_0000
        static let cmnReturnedAttrs: UInt32 = 0x8000_0000
        static let dirMountStatus: UInt32 = 0x0000_0004
        static let fileLinkCount: UInt32 = 0x0000_0001
        static let fileAllocSize: UInt32 = 0x0000_0004
        static let fileDataLength: UInt32 = 0x0000_0200
        static let typeDirectory: UInt32 = 2   // VDIR
        static let typeRegular: UInt32 = 1     // VREG
        static let mountPointFlag: UInt32 = 0x1 // DIR_MNTSTATUS_MNTPOINT
    }

    private static let bufferSize = 256 * 1024

    /// How many folders had to be read the classic way (for the scanner check).
    static var fallbacks: Int {
        fallbackLock.lock(); defer { fallbackLock.unlock() }
        return fallbackCount
    }
    nonisolated(unsafe) private static var fallbackCount = 0
    private static let fallbackLock = NSLock()

    /// Scans everything under `path` that's on the same disk. Runs on a background thread; blocks until done or cancelled.
    static func scan(path: String, title: String, progress: ScanProgress) -> RootNode {
        let began = Date()
        let real = DisplayName.realPath(path) ?? path
        var st = stat()
        guard lstat(real, &st) == 0 else {
            let r = RootNode(path: real, displayName: title, fileID: 0)
            r.flags.insert(.unreadable)
            return r
        }
        let root = RootNode(path: real, displayName: title, fileID: UInt64(st.st_ino))
        let dev = st.st_dev

        // List the top few levels here until there are enough folders to keep every core busy,
        // then hand each remaining folder to a worker as its own job.
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let target = workers * 8
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buf.deallocate() }
        var entries: [Entry] = []
        var frontier: [Job] = [Job(node: root, path: real)]
        var jobs: [Job] = []
        var level = 0
        var files = 0
        var bytes: Int64 = 0
        let seen = InodeSet()
        while !frontier.isEmpty {
            var next: [Job] = []
            for job in frontier {
                job.node.flags.insert(.split)
                guard read(job.path, dev: dev, into: &entries, buf: buf, node: job.node, progress: progress) else { continue }
                for e in entries {
                    if e.isDir {
                        if e.isMountPoint || e.dev != dev { continue }
                        let child = Node(name: e.name, size: 0, fileID: e.fileID, flags: [.directory])
                        job.node.add(child)
                        next.append(Job(node: child, path: join(job.path, e.name)))
                    } else {
                        let size = (e.links > 1 && !seen.insert(e.fileID)) ? 0 : e.size
                        job.node.add(Node(name: e.name, size: size, fileID: e.fileID, flags: []))
                        files += 1
                        bytes += size
                    }
                }
            }
            if next.count < target && level < 3 {
                frontier = next
                level += 1
            } else {
                jobs = next
                frontier = []
            }
        }
        progress.add(files: files, bytes: bytes, path: real)

        let ctx = Context(dev: dev, progress: progress, seen: seen, jobs: jobs)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let wbuf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
            defer { wbuf.deallocate() }
            var list: [Entry] = []
            while let job = ctx.take() {
                if !ctx.progress.cancelled { walk(job.node, path: job.path, ctx: ctx, buf: wbuf, entries: &list) }
                ctx.finished()
            }
        }

        // add everything up, bottom to top: each original job's folder in parallel, then the top levels
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in finalizeTree(jobs[i].node) }
        finishSplit(root)
        root.scanSeconds = Date().timeIntervalSince(began)
        root.skipped = progress.snapshot().skipped
        return root
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.hasSuffix("/") ? a + b : a + "/" + b
    }

    /// Opens a folder safely and reads its entries. Marks the node if it can't, or if it belongs to another disk.
    private static func read(_ path: String, dev: dev_t, into entries: inout [Entry], buf: UnsafeMutableRawPointer,
                             node: Node, progress: ScanProgress) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            node.flags.insert(.unreadable)
            progress.skipped()
            return false
        }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) == 0 && st.st_dev != dev {
            node.flags.insert(.excluded)   // another disk is mounted here
            return false
        }
        if !readEntries(fd: fd, buf: buf, into: &entries) {
            node.flags.insert(.unreadable)
            progress.skipped()
            return false
        }
        return true
    }

    /// Walks one folder (iteratively, no recursion), filling in `top`. Subfolders may be handed to other workers.
    private static func walk(_ top: Node, path: String, ctx: Context, buf: UnsafeMutableRawPointer, entries: inout [Entry]) {
        var stack: [Job] = [Job(node: top, path: path)]
        var files = 0
        var bytes: Int64 = 0
        var dirs = 0
        while let job = stack.popLast() {
            dirs += 1
            if dirs & 63 == 0 && ctx.progress.cancelled { break }
            guard read(job.path, dev: ctx.dev, into: &entries, buf: buf, node: job.node, progress: ctx.progress) else { continue }
            job.node.children.reserveCapacity(entries.count)
            let before = stack.count
            for e in entries {
                if e.isDir {
                    if e.isMountPoint || e.dev != ctx.dev { continue }
                    let child = Node(name: e.name, size: 0, fileID: e.fileID, flags: [.directory])
                    job.node.add(child)
                    stack.append(Job(node: child, path: join(job.path, e.name)))
                } else {
                    let size = (e.links > 1 && !ctx.seen.insert(e.fileID)) ? 0 : e.size
                    job.node.add(Node(name: e.name, size: size, fileID: e.fileID, flags: []))
                    files += 1
                    bytes += size
                }
            }
            // someone's idle: give them all but one of the subfolders just found
            if stack.count - before > 1 && (dirs & 7 == 0 || stack.count > 64) && ctx.hungry {
                ctx.share(stack[(before + 1)...])
                stack.removeSubrange((before + 1)...)
            }
            if files >= 4096 {
                ctx.progress.add(files: files, bytes: bytes, path: job.path)
                files = 0
                bytes = 0
            }
        }
        ctx.progress.add(files: files, bytes: bytes, path: nil)
    }

    /// Adds up a finished subtree, deepest folders first (iteratively, so very deep trees are fine).
    private static func finalizeTree(_ top: Node) {
        var stack = [top]
        var order: [Node] = []
        while let n = stack.popLast() {
            order.append(n)
            for c in n.children where c.isDir { stack.append(c) }
        }
        for n in order.reversed() { n.finalize() }
    }

    private static func finishSplit(_ node: Node) {
        // the split levels are shallow (at most 4), so recursion is fine here
        for c in node.children where c.flags.contains(.split) { finishSplit(c) }
        node.finalize()
    }

    // MARK: reading one folder

    /// Fills `out` with every entry of the open folder `fd`. False if the folder couldn't be read at all.
    static func readEntries(fd: Int32, buf: UnsafeMutableRawPointer, into out: inout [Entry]) -> Bool {
        out.removeAll(keepingCapacity: true)
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = A.cmnReturnedAttrs | A.cmnName | A.cmnDevID | A.cmnObjType | A.cmnFileID
        al.dirattr = A.dirMountStatus
        al.fileattr = A.fileLinkCount | A.fileAllocSize | A.fileDataLength

        while true {
            let count = getattrlistbulk(fd, &al, buf, bufferSize, 0)
            if count == 0 { return true }
            if count < 0 {
                // not supported on this disk, or an entry it couldn't describe: read this folder the classic way
                fallbackLock.lock(); fallbackCount += 1; fallbackLock.unlock()
                return readEntriesSlow(fd: fd, into: &out)
            }
            var p = UnsafeRawPointer(buf)
            let end = UnsafeRawPointer(buf) + bufferSize
            for _ in 0..<Int(count) {
                guard p + 24 <= end else { break }
                let length = Int(p.loadUnaligned(as: UInt32.self))
                guard length >= 24, p + length <= end else { break }
                // attribute_set_t of what was actually returned for this entry
                let rCommon = p.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                let rDir = p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                let rFile = p.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
                var off = 24
                var name: String?
                if rCommon & A.cmnName != 0, off + 8 <= length {
                    // attrreference_t: offset from this field to the string, and its length (including the NUL)
                    let nameOff = Int(p.loadUnaligned(fromByteOffset: off, as: Int32.self))
                    let nameLen = Int(p.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self))
                    let start = off + nameOff
                    if nameOff > 0, nameLen > 1, start + nameLen <= length {
                        name = String(decoding: UnsafeRawBufferPointer(start: p + start, count: nameLen - 1), as: UTF8.self)
                    }
                    off += 8
                }
                var dev: dev_t = 0
                if rCommon & A.cmnDevID != 0, off + 4 <= length {
                    dev = p.loadUnaligned(fromByteOffset: off, as: dev_t.self); off += 4
                }
                var type: UInt32 = 0
                if rCommon & A.cmnObjType != 0, off + 4 <= length {
                    type = p.loadUnaligned(fromByteOffset: off, as: UInt32.self); off += 4
                }
                var fileID: UInt64 = 0
                if rCommon & A.cmnFileID != 0, off + 8 <= length {
                    fileID = p.loadUnaligned(fromByteOffset: off, as: UInt64.self); off += 8
                }
                var mountPoint = false
                if rDir & A.dirMountStatus != 0, off + 4 <= length {
                    mountPoint = p.loadUnaligned(fromByteOffset: off, as: UInt32.self) & A.mountPointFlag != 0; off += 4
                }
                var links: UInt32 = 1
                if rFile & A.fileLinkCount != 0, off + 4 <= length {
                    links = p.loadUnaligned(fromByteOffset: off, as: UInt32.self); off += 4
                }
                var size: Int64 = 0
                if rFile & A.fileAllocSize != 0, off + 8 <= length {
                    size = p.loadUnaligned(fromByteOffset: off, as: Int64.self); off += 8
                }
                var dataLength: Int64 = 0
                if rFile & A.fileDataLength != 0, off + 8 <= length {
                    dataLength = p.loadUnaligned(fromByteOffset: off, as: Int64.self); off += 8
                }
                if let name = name, name != ".", name != ".." {
                    let isDir = type == A.typeDirectory
                    out.append(Entry(name: name, isDir: isDir, isFile: type == A.typeRegular, isMountPoint: mountPoint, dev: dev,
                                     fileID: fileID, links: links, size: isDir ? 0 : max(0, size),
                                     length: isDir ? 0 : max(0, dataLength)))
                }
                p += length
            }
        }
    }

    /// The classic way: readdir, then fstatat each entry (without following links).
    static func readEntriesSlow(fd: Int32, into out: inout [Entry]) -> Bool {
        out.removeAll(keepingCapacity: true)
        let dfd = dup(fd)
        guard dfd >= 0 else { return false }
        guard let dirp = fdopendir(dfd) else {
            close(dfd)
            return false
        }
        defer { closedir(dirp) }
        rewinddir(dirp)   // the fast path may already have moved through part of the folder
        var st = stat()
        while let ent = readdir(dirp) {
            let name: String = withUnsafePointer(to: ent.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ent.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let isDir = (Int(st.st_mode) & 0o170000) == 0o040000
            let isFile = (Int(st.st_mode) & 0o170000) == 0o100000
            out.append(Entry(name: name, isDir: isDir, isFile: isFile, isMountPoint: false, dev: st.st_dev,
                             fileID: UInt64(st.st_ino), links: UInt32(st.st_nlink),
                             size: isDir ? 0 : Int64(st.st_blocks) * 512,
                             length: isDir ? 0 : Int64(st.st_size)))
        }
        return true
    }
}
