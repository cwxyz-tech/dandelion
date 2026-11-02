// Dandelion - app state: scanning, navigation, the collector and the Trash.
// MIT License. See LICENSE.

import AppKit
import Darwin
import Foundation
import SwiftUI

/// What the pointer is over. Kept apart from AppState so moving the mouse only redraws the chart and the
/// list rows, not the whole window.
@MainActor
final class HoverModel: ObservableObject {
    @Published var node: Node?

    func set(_ n: Node?) {
        if node !== n { node = n }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let symbol: String
    let tint: Color

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

@MainActor
final class AppState: ObservableObject {
    enum Phase { case home, scanning, results }

    @Published var phase: Phase = .home
    @Published var volumes: [VolumeInfo] = []
    @Published var root: RootNode?
    @Published var focus: Node?
    @Published var selected: Node?
    @Published var collector: [Node] = []
    /// Bumped whenever the tree changes (after moving things to the Trash), so the chart redraws.
    @Published var version = 0
    @Published var scanTitle = ""
    @Published var live = ScanProgress.Snapshot()
    @Published var elapsed: Double = 0
    @Published var hasFullDiskAccess = true
    @Published var quickLookURL: URL?
    @Published var confirmTrash = false
    @Published var trashing = false
    @Published var toast: Toast?
    @Published var alertMessage: String?

    let hover = HoverModel()
    let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.1"
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var progress: ScanProgress?
    private var timer: Timer?
    private var lastScan: (path: String, title: String, isVolume: Bool)?
    private var toastTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        refreshVolumes()
        checkFullDiskAccess()
        // keep the disk list current when drives are plugged in, ejected or renamed
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in self.refreshVolumes() }
            })
        }
    }

    // MARK: disks and permissions

    func refreshVolumes() {
        volumes = VolumeInfo.list()
    }

    /// Without Full Disk Access, macOS hides parts of your Library (Mail, Messages, Safari, other apps' data) from every app.
    func checkFullDiskAccess() {
        let fd = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC)
        if fd >= 0 {
            Darwin.close(fd)
            hasFullDiskAccess = true
        } else {
            hasFullDiskAccess = false
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: scanning

    func scan(_ volume: VolumeInfo) {
        start(path: volume.scanPath, title: volume.name, isVolume: true)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan"
        if panel.runModal() == .OK, let url = panel.url {
            let name = FileManager.default.displayName(atPath: url.path)
            start(path: url.path, title: name, isVolume: false)
        }
    }

    var canRescan: Bool { lastScan != nil && phase != .scanning }

    func rescan() {
        guard let last = lastScan, phase != .scanning else { return }
        start(path: last.path, title: last.title, isVolume: last.isVolume)
    }

    private func start(path: String, title: String, isVolume: Bool) {
        progress?.cancel()
        timer?.invalidate()
        lastScan = (path, title, isVolume)
        let prog = ScanProgress()
        progress = prog
        scanTitle = title
        live = ScanProgress.Snapshot()
        elapsed = 0
        dropTree()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { phase = .scanning }

        let began = Date()
        // (AppState lives as long as the app, so holding on to it here is fine)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in self.tick(prog, began: began) }
        }

        Task.detached(priority: .userInitiated) {
            let tree = Scanner.scan(path: path, title: title, progress: prog)
            let hidden = isVolume ? AppState.hiddenBytes(path: path, scanned: tree.size) : 0
            await self.finish(tree, hidden: hidden, progress: prog)
        }
    }

    private func tick(_ prog: ScanProgress, began: Date) {
        guard progress === prog, phase == .scanning else { return }
        live = prog.snapshot()
        elapsed = Date().timeIntervalSince(began)
    }

    /// Space the disk says is used that the scan didn't find: the sealed system volume, snapshots,
    /// purgeable caches, other volumes sharing the disk, and anything we weren't allowed to read.
    nonisolated static func hiddenBytes(path: String, scanned: Int64) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacity else { return 0 }
        return max(0, Int64(total) - Int64(avail) - scanned)
    }

    private func finish(_ tree: RootNode, hidden: Int64, progress prog: ScanProgress) {
        guard progress === prog else {
            AppState.release(tree)   // a newer scan replaced this one
            return
        }
        timer?.invalidate()
        timer = nil
        if prog.cancelled {
            AppState.release(tree)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { phase = .home }
            refreshVolumes()
            return
        }
        if hidden > 0 {
            let h = Node(name: "Hidden space", size: hidden, fileID: 0, flags: [.synthetic])
            tree.add(h)
            tree.finalize()
        }
        root = tree
        focus = tree
        version += 1
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { phase = .results }
        checkFullDiskAccess()
    }

    func cancelScan() {
        progress?.cancel()
        timer?.invalidate()
        timer = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { phase = .home }
        refreshVolumes()
    }

    func goHome() {
        progress?.cancel()
        dropTree()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { phase = .home }
        refreshVolumes()
        checkFullDiskAccess()
    }

    /// Lets go of the current tree. A big disk is millions of objects, so they're freed on a background
    /// thread instead of freezing the window for a moment.
    private func dropTree() {
        let old = root
        root = nil
        focus = nil
        selected = nil
        hover.set(nil)
        collector = []
        Icons.shared.forget()
        if let old = old { AppState.release(old) }
    }

    nonisolated private static func release(_ tree: RootNode) {
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(tree) {} }
    }

    // MARK: moving around

    func zoom(into node: Node) {
        guard node.isDir, !node.isSynthetic else {
            selected = node
            return
        }
        hover.set(nil)
        selected = nil
        focus = node
    }

    func up() {
        guard let p = focus?.parent else { return }
        hover.set(nil)
        focus = p
    }

    var canGoUp: Bool { focus?.parent != nil }

    /// Finds the scanned item at a path (for things dropped onto the collector).
    func node(forPath rawPath: String) -> Node? {
        guard let r = root else { return nil }
        let rootPath = r.path
        var p = DisplayName.realPath(rawPath) ?? rawPath
        if p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        // on the startup disk, /Users/... really lives at /System/Volumes/Data/Users/...
        if rootPath == "/System/Volumes/Data" && !p.hasPrefix(rootPath) { p = rootPath + p }
        if p == rootPath { return r }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard p.hasPrefix(prefix) else { return nil }
        var cur: Node = r
        for comp in p.dropFirst(prefix.count).split(separator: "/") {
            guard let next = cur.children.first(where: { $0.name == comp }) else { return nil }
            cur = next
        }
        return cur
    }

    // MARK: the collector

    func collect(_ node: Node) {
        if let reason = Safety.protectionReason(node) {
            show(Toast(text: reason, symbol: "lock.fill", tint: .orange))
            NSSound.beep()
            return
        }
        if collector.contains(where: { $0.isAncestor(of: node) }) { return }   // already in there (or its folder is)
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75)) {
            collector.removeAll { node.isAncestor(of: $0) }                    // its folder replaces anything inside it
            collector.append(node)
        }
    }

    func uncollect(_ node: Node) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            collector.removeAll { $0 === node }
        }
    }

    func clearCollector() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { collector = [] }
    }

    func isCollected(_ node: Node) -> Bool {
        collector.contains { $0.isAncestor(of: node) }
    }

    var collectedBytes: Int64 { collector.reduce(0) { $0 + $1.size } }

    /// Moves everything in the collector to the Trash (nothing is ever deleted outright).
    /// Each item is checked first: still the same file, in the same folder, and not something macOS needs.
    func trashCollected() {
        guard !collector.isEmpty, !trashing else { return }
        let items = collector
        let jobs: [(Node, String)] = items.map { ($0, $0.path) }
        trashing = true
        Task.detached(priority: .userInitiated) {
            var moved: [Node] = []
            var failed: [String] = []
            for (node, path) in jobs {
                if let reason = Safety.protectionReason(node) ?? Safety.verify(node) {
                    failed.append(reason)
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    moved.append(node)
                } catch {
                    failed.append("\(node.title): \(error.localizedDescription)")
                }
            }
            await self.finishTrash(moved: moved, failed: failed)
        }
    }

    private func finishTrash(moved: [Node], failed: [String]) {
        trashing = false
        let freed = moved.reduce(Int64(0)) { $0 + $1.size }
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
            for n in moved { n.removeFromTree() }
            collector.removeAll { n in moved.contains { $0 === n } }
            if let r = root {
                if let f = focus, !r.isAncestor(of: f) { focus = r }
                if let s = selected, !r.isAncestor(of: s) { selected = nil }
            }
            hover.set(nil)
            version += 1
        }
        if !moved.isEmpty {
            playTrashSound()
            show(Toast(text: "Moved \(moved.count == 1 ? "1 item" : "\(moved.count) items") to the Trash · \(Fmt.bytes(freed)) back once you empty it",
                       symbol: "trash.fill", tint: .green))
        }
        if !failed.isEmpty {
            alertMessage = (moved.isEmpty ? "Nothing was moved:" : "Some items weren't moved:") + "\n\n" + failed.joined(separator: "\n")
        }
    }

    private func playTrashSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif"
        if FileManager.default.fileExists(atPath: path) {
            NSSound(contentsOfFile: path, byReference: true)?.play()
        }
    }

    // MARK: toasts

    func show(_ t: Toast) {
        toastTask?.cancel()
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) { toast = t }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if Task.isCancelled { return }
            withAnimation(self.reduceMotion ? nil : .easeIn(duration: 0.25)) { self.toast = nil }
        }
    }

    // MARK: file actions

    func reveal(_ node: Node) {
        guard !node.isSynthetic else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func open(_ node: Node) {
        guard !node.isSynthetic else { return }
        NSWorkspace.shared.open(node.url)
    }

    func copyPath(_ node: Node) {
        guard !node.isSynthetic else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
        show(Toast(text: "Copied the path", symbol: "doc.on.doc.fill", tint: .blue))
    }

    func quickLook(_ node: Node?) {
        guard let n = node, !n.isSynthetic else { return }
        quickLookURL = n.url
    }

    // MARK: describing things

    func detail(for node: Node) -> String {
        if node.isSynthetic { return "System, snapshots, purgeable space and anything unreadable" }
        if node.unreadable { return "No permission to look inside" }
        if node.isDir { return Fmt.items(node.fileCount) }
        let ext = (node.name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(DisplayName.clean(ext)) file"
    }
}
