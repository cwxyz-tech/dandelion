// Dandelion - scanner check. Runs on a real Mac in CI (see Tests/run.sh).
// Builds a tricky folder tree, scans it, and compares every total with the classic fts walk
// (the method `du` uses). Then does the same on a real system folder and compares speed.

import Darwin
import Foundation

@main
struct ScanCheck {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS  " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    /// The reference: fts, physical walk, one disk, hard links once. Counts files and their allocated bytes.
    static func reference(_ path: String) -> (files: Int, bytes: Int64) {
        guard let c = strdup(path) else { return (0, 0) }
        defer { free(c) }
        var argv: [UnsafeMutablePointer<CChar>?] = [c, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return (0, 0) }
        defer { fts_close(fts) }
        var seen = Set<UInt64>()
        var files = 0
        var bytes: Int64 = 0
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT {
                let st: UnsafeMutablePointer<stat>? = ent.pointee.fts_statp
                guard let s = st else { continue }
                files += 1
                if s.pointee.st_nlink > 1 && !seen.insert(UInt64(s.pointee.st_ino)).inserted { continue }
                bytes += Int64(s.pointee.st_blocks) * 512
            }
        }
        return (files, bytes)
    }

    static func find(_ root: Node, _ rel: String) -> Node? {
        var cur = root
        for comp in rel.split(separator: "/") {
            guard let next = cur.children.first(where: { $0.name == String(comp) }) else { return nil }
            cur = next
        }
        return cur
    }

    static func main() {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "dandelion-check-\(getpid())"
        try? fm.removeItem(atPath: base)
        try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)

        func write(_ rel: String, _ size: Int) {
            let p = base + "/" + rel
            try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var bytes = [UInt8](repeating: 0, count: size)
            for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
            fm.createFile(atPath: p, contents: Data(bytes))
        }

        // ---- build the tree ----
        for (i, n) in [0, 1, 4095, 4096, 4097, 1_000_000, 10_000_000].enumerated() { write("sizes/file\(i).bin", n) }
        for i in 0..<6000 { write("many/item-\(i).txt", 100 + i % 300) }          // more than one batch from getattrlistbulk
        var deep = "deep"
        for _ in 0..<70 { deep += "/d" }
        write(deep + "/leaf.bin", 5000)
        write("links/big.bin", 3_000_000)
        _ = link(base + "/links/big.bin", base + "/links/big-hardlink.bin")
        _ = symlink(base + "/links/big.bin", base + "/links/symlink-to-big")
        write("names/naïve café 🌼.txt", 1234)
        write("names/we\u{202E}ird\nname.txt", 99)
        try? fm.createDirectory(atPath: base + "/empty", withIntermediateDirectories: true)
        write("locked/secret.bin", 50_000)
        chmod(base + "/locked", 0)

        // ---- scan ----
        let progress = ScanProgress()
        let root = Scanner.scan(path: base, title: "check", progress: progress)
        let ref = reference(base)
        print("tree: \(root.fileCount) files, \(root.size) bytes  |  fts: \(ref.files) files, \(ref.bytes) bytes")

        check(root.size == ref.bytes, "total size matches fts")
        check(Int(root.fileCount) == ref.files, "file count matches fts")
        check(root.realPath == DisplayName.realPath(base), "root uses the real path")
        check(find(root, "many")?.children.count == 6000, "a folder bigger than one read batch is read completely")
        if let leaf = find(root, deep + "/leaf.bin") {
            check(leaf.path == root.realPath + "/" + deep + "/leaf.bin", "deep paths are rebuilt correctly")
            check(leaf.size > 0, "deep file has a size")
        } else { check(false, "found the file 70 folders deep") }
        let big = find(root, "links/big.bin")?.size ?? -1
        let hard = find(root, "links/big-hardlink.bin")?.size ?? -1
        check(big >= 0 && hard >= 0 && min(big, hard) == 0 && max(big, hard) > 0, "hard link counted once")
        let sym = find(root, "links/symlink-to-big")?.size ?? -1
        check(sym >= 0 && sym < 100_000, "symlink isn't followed")
        check(find(root, "names/naïve café 🌼.txt") != nil, "unicode names survive")
        if let weird = find(root, "names")?.children.first(where: { $0.name.hasPrefix("we") }) {
            check(!weird.title.contains("\u{202E}") && !weird.title.contains("\n"), "spoofing characters are made visible")
        } else { check(false, "found the weird name") }
        check(find(root, "empty").map { $0.size == 0 && $0.children.isEmpty } ?? false, "empty folder")
        if getuid() != 0 {
            check(find(root, "locked")?.unreadable ?? false, "unreadable folder is flagged")
            check(root.skipped >= 1, "unreadable folder is counted as skipped")
        }
        check(find(root, "sizes")?.children.first?.name == "file6.bin", "children sorted biggest first")

        // the fast path and the classic path read a folder the same way
        let fd = open(base + "/many", O_RDONLY | O_DIRECTORY)
        var fast: [Scanner.Entry] = []
        var slow: [Scanner.Entry] = []
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        _ = Scanner.readEntries(fd: fd, buf: buf, into: &fast)
        _ = Scanner.readEntriesSlow(fd: fd, into: &slow)
        buf.deallocate()
        close(fd)
        let fastMap = Dictionary(fast.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
        let slowMap = Dictionary(slow.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
        check(fast.count == 6000 && fastMap == slowMap, "getattrlistbulk and readdir agree (\(fast.count) entries)")
        check(Set(fast.map { $0.fileID }) == Set(slow.map { $0.fileID }), "file IDs agree")

        chmod(base + "/locked", 0o755)
        try? fm.removeItem(atPath: base)

        // ---- a real folder: correctness and speed ----
        let real = fm.fileExists(atPath: "/Applications/Xcode.app") ? "/Applications/Xcode.app" : "/usr"
        let t0 = Date()
        let r = Scanner.scan(path: real, title: "real", progress: ScanProgress())
        let fastTime = Date().timeIntervalSince(t0)
        let t1 = Date()
        let rr = reference(real)
        let ftsTime = Date().timeIntervalSince(t1)
        let diff = abs(Double(r.size - rr.bytes)) / Double(max(1, rr.bytes))
        print(String(format: "real (%@): Dandelion %d files %.2f GB in %.2fs | fts %d files %.2f GB in %.2fs | %.1fx faster",
                     real, Int(r.fileCount), Double(r.size) / 1e9, fastTime, rr.files, Double(rr.bytes) / 1e9, ftsTime,
                     ftsTime / max(0.001, fastTime)))
        check(diff < 0.005, String(format: "real folder total within 0.5%% of fts (%.4f%%)", diff * 100))
        check(abs(Int(r.fileCount) - rr.files) <= max(5, rr.files / 1000), "real folder file count matches fts")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
