// Dandelion - checks for the Duplicate Finder and Folder Rules engines, plus the entry point
// that runs every check. Runs on a real Mac in CI (see Tests/run.sh).

import Darwin
import Foundation

@main
struct Checks {
    static func main() {
        print("== Disk scanner")
        ScanCheck.run()
        print("== Duplicate Finder")
        DupCheck.run()
        print("== Folder Rules")
        RulesCheck.run()
        print("== Tree after trashing")
        TreeCheck.run()
        let failures = ScanCheck.failures
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}

private func check(_ ok: Bool, _ what: String) { ScanCheck.check(ok, what) }

private func makeTemp(_ name: String) -> String {
    let base = NSTemporaryDirectory() + "dandelion-\(name)-\(getpid())"
    try? FileManager.default.removeItem(atPath: base)
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return DisplayName.realPath(base) ?? base
}

private func write(_ path: String, bytes: [UInt8]) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(bytes))
}

private func pattern(_ n: Int, seed: UInt8) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: n)
    for i in 0..<n { b[i] = UInt8(truncatingIfNeeded: i &* 131 &+ Int(seed) &* 7) }
    return b
}

enum DupCheck {
    static func run() {
        let base = makeTemp("dups")
        let photo = pattern(300_000, seed: 1)
        write(base + "/a/photo.jpg", bytes: photo)
        write(base + "/b/photo copy.jpg", bytes: photo)
        write(base + "/b/deep/again/photo (2).jpg", bytes: photo)                     // three copies
        let video = pattern(3_000_000, seed: 2)
        write(base + "/a/clip.mov", bytes: video)
        write(base + "/c/clip-backup.mov", bytes: video)                               // two copies, bigger than 64 KB head
        var almost = video; almost[2_999_000] ^= 0xFF
        write(base + "/c/clip-edited.mov", bytes: almost)                              // same size and same start, different end
        write(base + "/a/unique.bin", bytes: pattern(300_000, seed: 9))                // same size as photo, different bytes
        write(base + "/a/small1.txt", bytes: pattern(500, seed: 3))
        write(base + "/a/small2.txt", bytes: pattern(500, seed: 3))                    // below the minimum size
        write(base + "/a/empty1", bytes: [])
        write(base + "/a/empty2", bytes: [])
        _ = link(base + "/a/unique.bin", base + "/c/unique-hardlink.bin")              // same file, not a duplicate
        _ = symlink(base + "/a/photo.jpg", base + "/c/photo-link.jpg")                 // a link, not a file
        write(base + "/Thing.app/Contents/photo.jpg", bytes: photo)                    // inside a package: left alone
        write(base + "/a/.hidden-photo.jpg", bytes: photo)                             // hidden: skipped by default

        let progress = DupProgress()
        let groups = DuplicateFinder.find(in: [base], options: .init(minimumLength: 100 * 1024), progress: progress)
        let byName = groups.map { Set($0.files.map { $0.name }) }
        check(groups.count == 2, "found exactly the two duplicate sets (\(groups.count))")
        check(byName.contains(["photo.jpg", "photo copy.jpg", "photo (2).jpg"]), "three copies of the photo, nothing else in that set")
        check(byName.contains(["clip.mov", "clip-backup.mov"]), "the video and its backup, not the edited copy")
        check(!byName.joined().contains("unique-hardlink.bin") && !byName.joined().contains("unique.bin"), "hard links aren't duplicates")
        check(!byName.joined().contains("photo-link.jpg"), "symlinks are ignored")
        check(!groups.flatMap { $0.files }.contains { $0.path.contains("Thing.app") }, "packages are never opened up")
        check(!byName.joined().contains(".hidden-photo.jpg"), "hidden files skipped by default")
        check(groups.first.map { Set($0.files.map { $0.name }).contains("clip.mov") } ?? false, "biggest savings listed first")
        if let g = groups.first(where: { $0.files.count == 2 }) {
            check(g.reclaimable > 2_900_000, "reclaimable space is one copy's size")
            check(!g.hash.isEmpty, "full-file hash recorded for big files")
        }
        let withSmall = DuplicateFinder.find(in: [base], options: .init(minimumLength: 1), progress: DupProgress())
        check(withSmall.contains { Set($0.files.map { $0.name }) == ["small1.txt", "small2.txt"] }, "small files found when the minimum is lowered")
        check(!withSmall.contains { $0.files.contains { $0.name.hasPrefix("empty") } }, "empty files are never duplicates")
        let withHidden = DuplicateFinder.find(in: [base], options: .init(minimumLength: 100 * 1024, includeHidden: true), progress: DupProgress())
        check(withHidden.contains { $0.files.count == 4 }, "hidden files included when asked")

        // keep rules and safety
        if let g = groups.first(where: { $0.files.count == 3 }) {
            let keep = DuplicateFinder.keeper(g, rule: .shortestPath)
            check(keep?.name == "photo.jpg" || keep?.name == "photo copy.jpg", "keep-nearest-the-top picks a shallow copy")
            let f = g.files[0]
            check(DuplicateFinder.verify(f) == nil, "an untouched file passes the safety check")
            write(f.path, bytes: pattern(300_000, seed: 5))
            check(DuplicateFinder.verify(f) != nil, "an edited file fails the safety check")
        }
        let known = DuplicateFinder.hash(base + "/a/small1.txt", limit: nil, progress: nil)
        check(known?.count == 64, "SHA-256 hashes are 64 hex characters")

        // speed on a real folder
        let real = DisplayName.realPath(FileManager.default.fileExists(atPath: "/Applications/Xcode.app") ? "/Applications/Xcode.app" : "/usr") ?? "/usr"
        let t0 = Date()
        let p = DupProgress()
        let found = DuplicateFinder.find(in: [real], options: .init(minimumLength: 100 * 1024), progress: p)
        let snap = p.snapshot()
        print(String(format: "real (%@): %d files looked at, %d compared, %d duplicate sets, %.1f MB reclaimable, %.2fs",
                     real, snap.files, snap.candidates, found.count, Double(found.reduce(0) { $0 + $1.reclaimable }) / 1e6,
                     Date().timeIntervalSince(t0)))
        check(snap.files > 0, "walked a real folder")

        try? FileManager.default.removeItem(atPath: base)
    }
}

enum RulesCheck {
    static func run() {
        let base = makeTemp("rules")
        let dl = base + "/Downloads"
        let old = Date().addingTimeInterval(-10 * 86400)
        func file(_ name: String, size: Int = 1000, age: Date? = nil) {
            write(dl + "/" + name, bytes: pattern(size, seed: 4))
            let when = age ?? Date().addingTimeInterval(-60)
            try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: dl + "/" + name)
        }
        file("old-installer.dmg", age: old)
        file("new-installer.dmg")
        file("Screenshot 2026-01-01 at 10.00.00.png", age: old)
        file("song.mp3", size: 3_000_000, age: old)
        file("notes.txt", age: old)
        file("movie.part", age: old)                                      // still downloading
        file(".DS_Store", age: old)                                        // hidden
        write(dl + "/fresh.zip", bytes: pattern(100, seed: 1))             // changed seconds ago
        try? FileManager.default.createDirectory(atPath: dl + "/Some Folder", withIntermediateDirectories: true)

        // modified-date rule, trash action: plan only, nothing touched
        var trashRule = FolderRule(name: "Old installers", folder: dl,
                                   conditions: [RuleCondition(kind: .kindIs, fileKind: .installer),
                                                RuleCondition(kind: .modifiedMoreThanDaysAgo, number: 7)],
                                   action: RuleAction(kind: .moveToTrash))
        let p1 = RulesEngine.plan(trashRule)
        check(p1.map { ($0.source as NSString).lastPathComponent } == ["old-installer.dmg"], "only the old installer matches (\(p1.count))")
        check(p1.first?.destination == nil, "trash action plans for the Trash")
        check(FileManager.default.fileExists(atPath: dl + "/old-installer.dmg"), "planning doesn't touch anything")
        trashRule.matchAll = false
        check(RulesEngine.plan(trashRule).count >= 4, "match-any widens the rule")

        // sort by type, then undo
        let sortRule = FolderRule(name: "Sort", folder: dl, conditions: [], action: RuleAction(kind: .sortByType))
        let p2 = RulesEngine.plan(sortRule)
        let names = Set(p2.map { ($0.source as NSString).lastPathComponent })
        check(!names.contains("movie.part") && !names.contains(".DS_Store") && !names.contains("fresh.zip") && !names.contains("Some Folder"),
              "skips downloads in progress, hidden files, just-changed files and folders")
        let r2 = RulesEngine.run(p2)
        check(r2.problems.isEmpty, "sorting ran without problems")
        check(FileManager.default.fileExists(atPath: dl + "/Installers/old-installer.dmg"), "installer sorted into Installers")
        check(FileManager.default.fileExists(atPath: dl + "/Screenshots/Screenshot 2026-01-01 at 10.00.00.png"), "screenshot recognized and sorted")
        check(FileManager.default.fileExists(atPath: dl + "/Audio/song.mp3"), "audio sorted into Audio")
        var restored: [String] = []
        let undoProblems = RulesEngine.undo(r2.done) { path, _ in restored.append(path) }
        check(undoProblems.isEmpty && FileManager.default.fileExists(atPath: dl + "/song.mp3"), "undo puts everything back")
        check(restored.count == r2.done.count && restored.contains(dl + "/song.mp3"), "undo reports where each file went back to")

        // undo never moves a different file that took the moved one's place
        let r2b = RulesEngine.run(RulesEngine.plan(sortRule))
        if let song = r2b.done.first(where: { $0.from.hasSuffix("/song.mp3") }) {
            try? FileManager.default.removeItem(atPath: song.to)
            write(song.to, bytes: [9, 9, 9])
            let probs = RulesEngine.undo([song])
            check(!probs.isEmpty && !FileManager.default.fileExists(atPath: dl + "/song.mp3"), "undo leaves a replaced file alone")
            try? FileManager.default.removeItem(atPath: song.to)
        } else { check(false, "song was sorted for the replaced-file undo check") }
        _ = RulesEngine.undo(r2b.done.filter { !$0.from.hasSuffix("/song.mp3") })
        file("song.mp3", size: 3_000_000, age: old)

        // "added" really means added: files written moments ago weren't added days ago, even with an old modified date
        let addedRule = FolderRule(name: "Added", folder: dl, conditions: [RuleCondition(kind: .addedMoreThanDaysAgo, number: 1)],
                                   action: RuleAction(kind: .moveToTrash))
        check(RulesEngine.plan(addedRule).isEmpty, "added-date condition uses the date added, not the date modified")
        // a negative number can't turn a condition into "everything"
        let negRule = FolderRule(name: "Neg", folder: dl, conditions: [RuleCondition(kind: .smallerThanMB, number: -5)],
                                 action: RuleAction(kind: .moveToTrash))
        check(RulesEngine.plan(negRule).isEmpty, "negative sizes match nothing")

        // never overwrite
        try? FileManager.default.createDirectory(atPath: base + "/Archive", withIntermediateDirectories: true)
        write(base + "/Archive/notes.txt", bytes: [1, 2, 3])
        let moveRule = FolderRule(name: "Archive notes", folder: dl, conditions: [RuleCondition(kind: .extensionIs, text: "txt, md")],
                                  action: RuleAction(kind: .moveTo, destination: base + "/Archive"))
        let r3 = RulesEngine.run(RulesEngine.plan(moveRule))
        check(FileManager.default.fileExists(atPath: base + "/Archive/notes 2.txt"), "a name clash gets a new name instead of overwriting")
        check((try? Data(contentsOf: URL(fileURLWithPath: base + "/Archive/notes.txt"))) == Data([1, 2, 3]), "the existing file is untouched")
        check(r3.done.count == 1, "one file moved")

        // a file swapped after planning is left alone
        file("swap.txt", age: old)
        let p4 = RulesEngine.plan(moveRule)
        try? FileManager.default.removeItem(atPath: dl + "/swap.txt")
        file("swap.txt", age: old)
        let r4 = RulesEngine.run(p4)
        check(r4.done.isEmpty && !r4.problems.isEmpty, "a file replaced after planning isn't moved")

        // unsafe rules are refused
        check(RulesEngine.problem(with: FolderRule(name: "Bad", folder: "/System", conditions: [], action: RuleAction(kind: .sortByType))) != nil,
              "rules can't watch system folders")
        check(RulesEngine.problem(with: FolderRule(name: "Wipe", folder: dl, conditions: [], action: RuleAction(kind: .moveToTrash))) != nil,
              "a trash rule with no conditions is refused")
        check(RulesEngine.problem(with: moveRule) == nil, "a sensible rule is accepted")

        // saving
        let store = URL(fileURLWithPath: base + "/rules.json")
        try? RulesEngine.save([trashRule, sortRule, moveRule], to: store)
        check(RulesEngine.load(from: store) == [trashRule, sortRule, moveRule], "rules save and load exactly")
        var st = stat()
        check(stat(store.path, &st) == 0 && (st.st_mode & 0o777) == 0o600, "the rules file is private to you")
        check(RulesEngine.templates(home: base).count == 3, "ready-made rules are available")
        check(FileKind.of(name: "Screen Recording 2026-01-01 at 1.00.00 PM.mov") == .screenshot, "screen recordings count as screenshots")
        check(RulesEngine.uniquePath(base + "/Archive/notes.txt").hasSuffix("notes 3.txt"), "unique names keep counting up")

        try? FileManager.default.removeItem(atPath: base)
    }
}

enum TreeCheck {
    static func run() {
        // root: big (10), mid (6), small (1). Trash most of big: mid has to come first now.
        let root = RootNode(path: "/tmp/x", displayName: "x", fileID: 1)
        let big = Node(name: "big", size: 0, fileID: 2, flags: [.directory])
        let mid = Node(name: "mid", size: 6, fileID: 3, flags: [])
        let small = Node(name: "small", size: 1, fileID: 4, flags: [])
        let a = Node(name: "a", size: 9, fileID: 5, flags: [])
        let b = Node(name: "b", size: 1, fileID: 6, flags: [])
        big.add(a); big.add(b); big.finalize()
        root.add(big); root.add(mid); root.add(small); root.finalize()
        check(root.children.map { $0.name } == ["big", "mid", "small"], "children start biggest first")
        a.removeFromTree()
        check(big.size == 1 && root.size == 8, "totals go down after trashing")
        check(root.children.map { $0.name } == ["mid", "big", "small"] || root.children.map { $0.name } == ["mid", "small", "big"],
              "a folder that shrank moves down, so nothing big gets hidden in the small-items slice")
        check(root.children.first?.name == "mid", "the biggest item is first again")
    }
}
