// Dandelion - app state: scanning, navigation, the collector and deleting.
// MIT License. See LICENSE.

import AppKit
import Darwin
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase { case home, scanning, results }

    @Published var phase: Phase = .home
    @Published var volumes: [VolumeInfo] = []
    @Published var root: Node?
    @Published var focus: Node?
    @Published var hovered: Node?
    @Published var selected: Node?
    @Published var collector: [Node] = []
    /// Bumped whenever the tree changes (after deleting), so the chart redraws.
    @Published var version = 0
    @Published var scanTitle = ""
    @Published var live = ScanProgress.Snapshot()
    @Published var elapsed: TimeInterval = 0
    @Published var skipped = 0
    @Published var hasFullDiskAccess = true
    @Published var quickLookURL: URL?
    @Published var confirmDelete = false
    @Published var alertMessage: String?

    private var progress: ScanProgress?
    private var timer: Timer?
    private var lastScan: (path: String, title: String, isVolume: Bool)?
    private var iconCache: [String: NSImage] = [:]

    init() {
        refreshVolumes()
        checkFullDiskAccess()
    }

    // MARK: disks and permissions

    func refreshVolumes() {
        volumes = VolumeInfo.list()
    }

    /// Without Full Disk Access, macOS hides parts of your Library (Mail, Messages, Safari, other apps' data) from every app.
    func checkFullDiskAccess() {
        let fd = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
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
        root = nil
        focus = nil
        hovered = nil
        selected = nil
        collector = []
        phase = .scanning

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

    private func finish(_ tree: Node, hidden: Int64, progress prog: ScanProgress) {
        guard progress === prog else { return }   // a newer scan replaced this one
        timer?.invalidate()
        timer = nil
        if prog.cancelled {
            phase = .home
            refreshVolumes()
            return
        }
        if hidden > 0 {
            let h = Node(name: "Hidden space", isDir: false, size: hidden)
            h.isSynthetic = true
            h.fileCount = 0
            tree.add(h)
            tree.finalize()
        }
        skipped = prog.snapshot().skipped
        root = tree
        focus = tree
        version += 1
        phase = .results
        checkFullDiskAccess()
    }

    func cancelScan() {
        progress?.cancel()
        timer?.invalidate()
        timer = nil
        phase = .home
        refreshVolumes()
    }

    func goHome() {
        progress?.cancel()
        phase = .home
        root = nil
        focus = nil
        hovered = nil
        selected = nil
        collector = []
        iconCache = [:]
        refreshVolumes()
        checkFullDiskAccess()
    }

    // MARK: moving around

    func zoom(into node: Node) {
        guard node.isDir, !node.isSynthetic else {
            selected = node
            return
        }
        hovered = nil
        selected = nil
        withAnimation(.easeOut(duration: 0.22)) { focus = node }
    }

    func up() {
        guard let p = focus?.parent else { return }
        hovered = nil
        withAnimation(.easeOut(duration: 0.22)) { focus = p }
    }

    var canGoUp: Bool { focus?.parent != nil }

    /// Finds the scanned item at a path (for things dropped onto the collector).
    func node(forPath rawPath: String) -> Node? {
        guard let r = root else { return nil }
        let rootPath = r.path
        var p = rawPath
        if p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        // on the startup disk, /Users/... really lives at /System/Volumes/Data/Users/...
        if rootPath == "/System/Volumes/Data" && !p.hasPrefix(rootPath) { p = rootPath + p }
        if p == rootPath { return r }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard p.hasPrefix(prefix) else { return nil }
        var cur = r
        for comp in p.dropFirst(prefix.count).split(separator: "/") {
            guard let next = cur.children.first(where: { $0.name == comp }) else { return nil }
            cur = next
        }
        return cur
    }

    // MARK: the collector

    func collect(_ node: Node) {
        guard node.canTouch else { return }
        if collector.contains(where: { $0.isAncestor(of: node) }) { return }   // already in there (or its folder is)
        collector.removeAll { node.isAncestor(of: $0) }                       // its folder replaces anything inside it
        withAnimation(.easeOut(duration: 0.2)) { collector.append(node) }
    }

    func uncollect(_ node: Node) {
        withAnimation(.easeOut(duration: 0.2)) { collector.removeAll { $0 === node } }
    }

    func isCollected(_ node: Node) -> Bool {
        collector.contains { $0.isAncestor(of: node) }
    }

    var collectedBytes: Int64 { collector.reduce(0) { $0 + $1.size } }

    /// Moves everything in the collector to the Trash (nothing is ever deleted outright).
    func trashCollected() {
        var failed: [String] = []
        for n in collector {
            do {
                try FileManager.default.trashItem(at: n.url, resultingItemURL: nil)
                n.removeFromTree()
            } catch {
                failed.append("\(n.title): \(error.localizedDescription)")
            }
        }
        collector = []
        if let r = root {
            if let f = focus, !r.isAncestor(of: f) { focus = r }
            if let s = selected, !r.isAncestor(of: s) { selected = nil }
        }
        hovered = nil
        version += 1
        if !failed.isEmpty {
            alertMessage = "These couldn't be moved to the Trash:\n\n" + failed.joined(separator: "\n")
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func quickLook(_ node: Node?) {
        guard let n = node, !n.isSynthetic else { return }
        quickLookURL = n.url
    }

    func icon(for node: Node) -> NSImage {
        if node.isSynthetic {
            return NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hidden space") ?? NSImage()
        }
        let key = node.path
        if let cached = iconCache[key] { return cached }
        let img = NSWorkspace.shared.icon(forFile: key)
        if iconCache.count > 4000 { iconCache.removeAll() }
        iconCache[key] = img
        return img
    }

    // MARK: describing things

    func detail(for node: Node) -> String {
        if node.isSynthetic {
            return "System files, snapshots, purgeable space and files Dandelion couldn't read"
        }
        if node.unreadable { return "No permission to look inside" }
        if node.isDir { return Fmt.items(node.fileCount) }
        return (node.name as NSString).pathExtension.uppercased().isEmpty
            ? "File" : (node.name as NSString).pathExtension.uppercased() + " file"
    }
}
