// Dandelion - the screens: pick a disk, scanning, and the results.
// MIT License. See LICENSE.

import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            switch state.phase {
            case .home: HomeView()
            case .scanning: ScanningView()
            case .results: ResultsView()
            }
        }
        .quickLookPreview($state.quickLookURL)
        .alert("Something went wrong", isPresented: Binding(
            get: { state.alertMessage != nil },
            set: { if !$0 { state.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.alertMessage ?? "")
        }
    }
}

// MARK: - Full Disk Access

struct AccessBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Give Dandelion Full Disk Access to see everything")
                    .font(.system(size: 12, weight: .semibold))
                Text("Without it, macOS hides some folders (Mail, Messages, other apps' data) and they show up as hidden space. Turn it on, then rescan.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { state.openFullDiskAccessSettings() }
            Button("Check Again") { state.checkFullDiskAccess() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.3)))
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                Text("Dandelion")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("See what's taking up space on your Mac, and clear it out.")
                    .foregroundStyle(.secondary)
            }
            if !state.hasFullDiskAccess {
                AccessBanner().frame(maxWidth: 600)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(state.volumes) { v in VolumeCard(volume: v) }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: 600, maxHeight: 360)
            HStack(spacing: 12) {
                Button {
                    state.chooseFolder()
                } label: {
                    Label("Scan a Folder…", systemImage: "folder")
                }
                .controlSize(.large)
                Button {
                    state.refreshVolumes()
                    state.checkFullDiskAccess()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
            }
            Spacer(minLength: 10)
            Text("Free and open source · MIT License")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VolumeCard: View {
    @EnvironmentObject var state: AppState
    let volume: VolumeInfo

    init(volume: VolumeInfo) { self.volume = volume }

    // View state is stored with State(...) directly instead of the @State attribute: in the macOS 26 SDK
    // @State is a macro, and the Command Line Tools don't ship the plugin that expands it.
    private var overStore = State(initialValue: false)
    private var over: Bool {
        get { overStore.wrappedValue }
        nonmutating set { overStore.wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: volume.icon)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(volume.name).font(.system(size: 15, weight: .semibold))
                    if volume.isStartup {
                        Text("Startup Disk")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                UsageBar(fraction: volume.usedFraction)
                    .frame(height: 8)
                Text("\(Fmt.bytes(volume.used)) used of \(Fmt.bytes(volume.total)) · \(Fmt.bytes(volume.free)) free")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 10)
            Button("Scan") { state.scan(volume) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(14)
        .background(Color.primary.opacity(over ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { over = $0 }
        .onTapGesture(count: 2) { state.scan(volume) }
    }
}

struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(fraction > 0.9 ? Color.red : fraction > 0.75 ? Color.orange : Color.accentColor)
                    .frame(width: max(4, g.size.width * min(1, fraction)))
            }
        }
    }
}

// MARK: - Scanning

struct ScanningView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ScanSpinner().frame(width: 160, height: 160)
            Text("Scanning \(state.scanTitle)…")
                .font(.system(size: 20, weight: .semibold))
            HStack(spacing: 28) {
                statBox(Fmt.count(state.live.files), "files")
                statBox(Fmt.bytes(state.live.bytes), "found")
                statBox(Fmt.duration(state.elapsed), "elapsed")
            }
            Text(state.live.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 560)
            Button("Cancel") { state.cancelScan() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statBox(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 90)
    }
}

/// Rings of colored arcs turning at different speeds, like a sunburst warming up.
struct ScanSpinner: View {
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = min(size.width, size.height) / 2
                for ring in 0..<4 {
                    let r = maxR * (0.42 + 0.15 * CGFloat(ring))
                    let speed = (ring % 2 == 0 ? 1.0 : -1.3) * (0.6 + 0.25 * Double(ring))
                    for k in 0..<(3 + ring) {
                        let start = t * speed + Double(k) * 2 * Double.pi / Double(3 + ring)
                        let len = 0.5 + 0.35 * sin(t * 1.7 + Double(k + ring))
                        var p = Path()
                        p.addArc(center: c, radius: r, startAngle: .radians(start), endAngle: .radians(start + len), clockwise: false)
                        let hue = (Double(k) / Double(3 + ring) + t * 0.05).truncatingRemainder(dividingBy: 1)
                        ctx.stroke(p, with: .color(Color(hue: hue, saturation: 0.6, brightness: 0.95)),
                                   style: StrokeStyle(lineWidth: maxR * 0.11, lineCap: .round))
                    }
                }
            }
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !state.hasFullDiskAccess {
                AccessBanner().padding(.horizontal, 12).padding(.top, 10)
            }
            if let focus = state.focus {
                HSplitView {
                    ItemList(node: focus, version: state.version)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                    VStack(spacing: 0) {
                        Breadcrumbs(node: focus)
                        SunburstView(focus: focus, version: state.version)
                            .padding(14)
                            .frame(minWidth: 420, minHeight: 380)
                    }
                }
            }
            Divider()
            CollectorBar()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { state.goHome() } label: { Label("Disks", systemImage: "internaldrive") }
                    .help("Back to the list of disks")
                Button { state.up() } label: { Label("Up", systemImage: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!state.canGoUp)
                    .help("Go up one folder (⌘↑)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.quickLook(state.selected ?? state.hovered) } label: { Label("Quick Look", systemImage: "eye") }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(state.selected == nil && state.hovered == nil)
                    .help("Quick Look (Space)")
                Button { state.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Scan again (⌘R)")
            }
        }
        .navigationTitle(state.root?.title ?? "Dandelion")
        .navigationSubtitle(subtitle)
        .alert("Move \(state.collector.count == 1 ? "1 item" : "\(state.collector.count) items") to the Trash?",
               isPresented: $state.confirmDelete) {
            Button("Move to Trash", role: .destructive) { state.trashCollected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("That's \(Fmt.bytes(state.collectedBytes)). The space comes back once you empty the Trash, and until then you can still put things back.")
        }
    }

    private var subtitle: String {
        guard let r = state.root else { return "" }
        var s = "\(Fmt.bytes(r.size)) · \(Fmt.items(r.fileCount))"
        if state.skipped > 0 { s += " · \(Fmt.count(state.skipped)) unreadable" }
        return s
    }
}

struct Breadcrumbs: View {
    @EnvironmentObject var state: AppState
    let node: Node

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let trail = node.ancestry
                ForEach(Array(trail.enumerated()), id: \.offset) { i, n in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        state.zoom(into: n)
                    } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: state.icon(for: n)).resizable().frame(width: 14, height: 14)
                            Text(n.title).lineLimit(1)
                        }
                        .font(.system(size: 12, weight: n === node ? .semibold : .regular))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(n === node ? Color.primary : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 32)
    }
}

struct ItemList: View {
    @EnvironmentObject var state: AppState
    let node: Node
    let version: Int

    private let limit = 400

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(node.children.prefix(limit))) { child in
                        ItemRow(node: child, parentSize: node.size)
                    }
                    if node.children.count > limit {
                        let rest = node.children.dropFirst(limit)
                        Text("\(Fmt.count(rest.count)) smaller items · \(Fmt.bytes(rest.reduce(0) { $0 + $1.size }))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    if node.children.isEmpty {
                        Text(node.unreadable ? "Dandelion wasn't allowed to look inside this folder." : "This folder is empty.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: state.icon(for: node)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(Fmt.bytes(node.size)) · \(Fmt.items(node.fileCount))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
        }
        .padding(10)
    }
}

struct ItemRow: View {
    @EnvironmentObject var state: AppState
    let node: Node
    let parentSize: Int64

    var body: some View {
        let lit = state.hovered === node
        let picked = state.selected === node
        let collected = state.isCollected(node)
        HStack(spacing: 8) {
            Image(nsImage: state.icon(for: node))
                .resizable()
                .frame(width: 20, height: 20)
                .opacity(collected ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(node.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(collected)
                    Spacer(minLength: 6)
                    Text(Fmt.bytes(node.size))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    Capsule()
                        .fill(node.isSynthetic ? Color.gray.opacity(0.5) : Color.accentColor.opacity(0.55))
                        .frame(width: max(2, g.size.width * share))
                }
                .frame(height: 3)
            }
            if node.isDir {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(picked ? Color.accentColor.opacity(0.2) : lit ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { state.hovered = node } else if state.hovered === node { state.hovered = nil }
        }
        .onTapGesture(count: 2) {
            if node.isDir { state.zoom(into: node) } else { state.open(node) }
        }
        .onTapGesture { state.selected = node }
        .onDrag {
            node.canTouch ? NSItemProvider(object: node.url as NSURL) : NSItemProvider()
        }
        .contextMenu { NodeMenu(node: node) }
        .help(node.isSynthetic ? state.detail(for: node) : node.path)
    }

    private var share: CGFloat {
        parentSize > 0 ? CGFloat(Double(node.size) / Double(parentSize)) : 0
    }
}

// MARK: - Collector

struct CollectorBar: View {
    @EnvironmentObject var state: AppState

    init() {}
    // View state is stored with State(...) directly instead of the @State attribute: in the macOS 26 SDK
    // @State is a macro, and the Command Line Tools don't ship the plugin that expands it.
    private var targetedStore = State(initialValue: false)
    private var targeted: Bool { targetedStore.wrappedValue }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 18))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            if state.collector.isEmpty {
                Text("Drag files and folders here to collect them, then move them to the Trash in one go.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.collector) { n in chip(n) }
                    }
                }
                Text(Fmt.bytes(state.collectedBytes))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Button("Clear") { withAnimation { state.collector = [] } }
                Button(role: .destructive) {
                    state.confirmDelete = true
                } label: {
                    Label("Move to Trash…", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .onDrop(of: [UTType.fileURL], isTargeted: targetedStore.projectedValue) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    let path = url.path
                    Task { @MainActor in
                        if let n = state.node(forPath: path) { state.collect(n) }
                    }
                }
            }
            return true
        }
    }

    private func chip(_ n: Node) -> some View {
        HStack(spacing: 5) {
            Image(nsImage: state.icon(for: n)).resizable().frame(width: 16, height: 16)
            Text(n.title).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 140)
            Text(Fmt.bytes(n.size)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            Button { state.uncollect(n) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .contextMenu {
            Button("Reveal in Finder") { state.reveal(n) }
            Button("Remove from Collector") { state.uncollect(n) }
        }
    }
}
