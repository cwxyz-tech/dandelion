// Dandelion - the screens: pick a disk, scanning, and the results.
// MIT License. See LICENSE.
//
// View state is stored with State(...) directly instead of the @State attribute: in the macOS 26 SDK
// @State is a macro, and the Command Line Tools don't ship the plugin that expands it.

import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A little entrance: fade and slide in, one after another.
private func entrance(_ index: Int, reduce: Bool) -> Animation? {
    reduce ? nil : .spring(response: 0.42, dampingFraction: 0.82).delay(Double(min(index, 24)) * 0.018)
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            switch state.phase {
            case .home:
                HomeView().transition(.opacity.combined(with: .scale(scale: 0.985)))
            case .scanning:
                ScanningView().transition(.opacity.combined(with: .scale(scale: 1.02)))
            case .results:
                ResultsView().transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = state.toast {
                ToastView(toast: t)
                    .padding(.bottom, state.phase == .results ? 72 : 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(t.id)
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

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).foregroundStyle(toast.tint)
            Text(toast.text).font(.system(size: 12, weight: .medium)).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(maxWidth: 560)
    }
}

// MARK: - Full Disk Access

struct AccessBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating, isActive: !state.reduceMotion)
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
            Button("Check Again") { withAnimation { state.checkFullDiskAccess() } }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var state: AppState
    private var shownStore = State(initialValue: false)
    init() {}

    var body: some View {
        let shown = shownStore.wrappedValue
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                    .scaleEffect(shown ? 1 : 0.6)
                    .rotationEffect(.degrees(shown ? 0 : -25))
                Text("Dandelion")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("See what's taking up space on your Mac, and clear it out.")
                    .foregroundStyle(.secondary)
            }
            .opacity(shown ? 1 : 0)
            if !state.hasFullDiskAccess {
                AccessBanner().frame(maxWidth: 620)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(state.volumes.enumerated()), id: \.element.id) { i, v in
                        VolumeCard(volume: v, index: i)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: 620, maxHeight: 380)
            HStack(spacing: 12) {
                Button {
                    state.chooseFolder()
                } label: {
                    Label("Scan a Folder…", systemImage: "folder")
                }
                .controlSize(.large)
                Button {
                    withAnimation { state.refreshVolumes(); state.checkFullDiskAccess() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
            }
            Spacer(minLength: 10)
            Text("Version \(state.appVersion) · Free and open source · MIT License")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if state.reduceMotion { shownStore.wrappedValue = true; return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { shownStore.wrappedValue = true }
        }
    }
}

struct VolumeCard: View {
    @EnvironmentObject var state: AppState
    let volume: VolumeInfo
    let index: Int
    private var overStore = State(initialValue: false)
    private var shownStore = State(initialValue: false)

    init(volume: VolumeInfo, index: Int) {
        self.volume = volume
        self.index = index
    }

    var body: some View {
        let over = overStore.wrappedValue
        let shown = shownStore.wrappedValue
        HStack(spacing: 14) {
            Image(nsImage: Icons.shared.icon(forPath: volume.mountURL.path))
                .resizable()
                .frame(width: 48, height: 48)
                .scaleEffect(over ? 1.06 : 1)
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
                UsageBar(fraction: shown ? volume.usedFraction : 0)
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
        .background(Color.primary.opacity(over ? 0.075 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { inside in
            withAnimation(state.reduceMotion ? nil : .easeOut(duration: 0.15)) { overStore.wrappedValue = inside }
        }
        .onTapGesture(count: 2) { state.scan(volume) }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 14)
        .onAppear {
            if state.reduceMotion { shownStore.wrappedValue = true; return }
            withAnimation(entrance(index + 3, reduce: false)) { shownStore.wrappedValue = true }
        }
    }
}

struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: barColors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(fraction > 0 ? 4 : 0, g.size.width * min(1, fraction)))
            }
        }
    }

    private var barColors: [Color] {
        fraction > 0.9 ? [.orange, .red] : fraction > 0.75 ? [.yellow, .orange] : [Color.accentColor.opacity(0.75), Color.accentColor]
    }
}

// MARK: - Scanning

struct ScanningView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ScanSpinner(reduce: state.reduceMotion).frame(width: 170, height: 170)
            Text("Scanning \(state.scanTitle)…")
                .font(.system(size: 20, weight: .semibold))
            HStack(spacing: 28) {
                statBox(Fmt.count(state.live.files), "files")
                statBox(Fmt.bytes(state.live.bytes), "found")
                statBox(Fmt.duration(state.elapsed), "elapsed")
            }
            .animation(state.reduceMotion ? nil : .snappy(duration: 0.2), value: state.live.files)
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
                .contentTransition(.numericText())
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 96)
    }
}

/// Rings of colored arcs turning at different speeds around a gently pulsing seed head.
struct ScanSpinner: View {
    let reduce: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduce)) { tl in
            Canvas { ctx, size in
                let t = reduce ? 0 : tl.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = min(size.width, size.height) / 2
                for ring in 0..<4 {
                    let r = maxR * (0.42 + 0.15 * CGFloat(ring))
                    let speed = (ring % 2 == 0 ? 1.0 : -1.3) * (0.6 + 0.25 * Double(ring))
                    let n = 3 + ring
                    for k in 0..<n {
                        let start = t * speed + Double(k) * 2 * Double.pi / Double(n)
                        let len = 0.5 + 0.35 * sin(t * 1.7 + Double(k + ring))
                        var p = Path()
                        p.addArc(center: c, radius: r, startAngle: .radians(start), endAngle: .radians(start + len), clockwise: false)
                        let hue = (Double(k) / Double(n) + t * 0.05).truncatingRemainder(dividingBy: 1)
                        ctx.stroke(p, with: .color(Color(hue: hue, saturation: 0.6, brightness: 0.95)),
                                   style: StrokeStyle(lineWidth: maxR * 0.11, lineCap: .round))
                    }
                }
                let pulse = 1 + 0.07 * CGFloat(sin(t * 3))
                let s = maxR * 0.27 * pulse
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2)),
                         with: .color(Color(red: 1, green: 0.96, blue: 0.84)))
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
        .overlay {
            if state.trashing {
                ZStack {
                    Color.black.opacity(0.12)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Moving to the Trash…").font(.system(size: 13, weight: .medium))
                    }
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .transition(.opacity)
            }
        }
        .animation(state.reduceMotion ? nil : .easeOut(duration: 0.2), value: state.trashing)
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
                Button { if let n = state.selected ?? state.hover.node { state.collect(n) } } label: {
                    Label("Collect", systemImage: "tray.and.arrow.down")
                }
                .keyboardShortcut(.delete, modifiers: [])
                .help("Add the selected item to the collector (⌫)")
                Button { state.quickLook(state.selected ?? state.hover.node) } label: { Label("Quick Look", systemImage: "eye") }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Quick Look (Space)")
                Button { state.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Scan again (⌘R)")
            }
        }
        .navigationTitle(state.root?.title ?? "Dandelion")
        .navigationSubtitle(subtitle)
        .alert("Move \(state.collector.count == 1 ? "1 item" : "\(state.collector.count) items") to the Trash?",
               isPresented: $state.confirmTrash) {
            Button("Move to Trash", role: .destructive) { state.trashCollected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("That's \(Fmt.bytes(state.collectedBytes)). The space comes back once you empty the Trash, and until then you can still put things back. Each item is checked first to make sure it hasn't changed since the scan.")
        }
    }

    private var subtitle: String {
        guard let r = state.root else { return "" }
        var s = "\(Fmt.bytes(r.size)) · \(Fmt.items(r.fileCount)) · scanned in \(Fmt.duration(r.scanSeconds))"
        if r.skipped > 0 { s += " · \(Fmt.count(r.skipped)) unreadable" }
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
                ForEach(Array(trail.enumerated()), id: \.element.id) { i, n in
                    HStack(spacing: 2) {
                        if i > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            state.zoom(into: n)
                        } label: {
                            HStack(spacing: 4) {
                                Image(nsImage: Icons.shared.icon(for: n)).resizable().frame(width: 14, height: 14)
                                Text(n.title).lineLimit(1)
                            }
                            .font(.system(size: 12, weight: n === node ? .semibold : .regular))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(n === node ? Color.primary.opacity(0.07) : Color.clear, in: Capsule())
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(n === node ? Color.primary : Color.secondary)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .animation(state.reduceMotion ? nil : .snappy(duration: 0.25), value: node)
        }
        .frame(height: 34)
    }
}

struct ItemList: View {
    @EnvironmentObject var state: AppState
    let node: Node
    let version: Int

    init(node: Node, version: Int) {
        self.node = node
        self.version = version
    }

    private let limit = 400

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(node.children.prefix(limit).enumerated()), id: \.element.id) { i, child in
                        ItemRow(node: child, parentSize: node.size, index: i)
                    }
                    if node.children.count > limit {
                        let rest = node.children.dropFirst(limit)
                        Text("\(Fmt.count(rest.count)) smaller items · \(Fmt.bytes(rest.reduce(Int64(0)) { $0 + $1.size }))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    if node.children.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: node.unreadable ? "lock.fill" : "tray")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text(node.unreadable ? "Dandelion wasn't allowed to look inside this folder." : "This folder is empty.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                    }
                }
                .id(node.id)   // a new folder gets fresh rows, which animate in
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: Icons.shared.icon(for: node)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(Fmt.bytes(node.size)) · \(Fmt.items(node.fileCount))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
        }
        .padding(10)
        .animation(state.reduceMotion ? nil : .snappy(duration: 0.25), value: node.size)
    }
}

struct ItemRow: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var hover: HoverModel
    let node: Node
    let parentSize: Int64
    let index: Int
    private var shownStore = State(initialValue: false)

    init(node: Node, parentSize: Int64, index: Int) {
        self.node = node
        self.parentSize = parentSize
        self.index = index
    }

    var body: some View {
        let lit = hover.node === node
        let picked = state.selected === node
        let collected = state.isCollected(node)
        let shown = shownStore.wrappedValue
        HStack(spacing: 8) {
            Image(nsImage: Icons.shared.icon(for: node))
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
                        .fill(node.isSynthetic ? Color.gray.opacity(0.5) : Color.accentColor.opacity(lit ? 0.85 : 0.55))
                        .frame(width: max(2, g.size.width * (shown ? share : 0)))
                }
                .frame(height: 3)
            }
            if node.isDir {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: lit ? 2 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(picked ? Color.accentColor.opacity(0.2) : lit ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .opacity(shown ? 1 : 0)
        .offset(x: shown ? 0 : 12)
        .animation(state.reduceMotion ? nil : .easeOut(duration: 0.12), value: lit)
        .onAppear {
            if state.reduceMotion || index > 30 { shownStore.wrappedValue = true; return }
            withAnimation(entrance(index, reduce: false)) { shownStore.wrappedValue = true }
        }
        .onHover { inside in
            if inside { hover.set(node) } else if hover.node === node { hover.set(nil) }
        }
        .onTapGesture(count: 2) {
            if node.isDir { state.zoom(into: node) } else { state.open(node) }
        }
        .onTapGesture { state.selected = node }
        .onDrag {
            node.canTouch ? NSItemProvider(object: node.url as NSURL) : NSItemProvider()
        }
        .contextMenu { NodeMenu(node: node) }
        .help(node.isSynthetic ? state.detail(for: node) : DisplayName.clean(node.path))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title), \(Fmt.bytes(node.size))")
    }

    private var share: CGFloat {
        parentSize > 0 ? CGFloat(Double(node.size) / Double(parentSize)) : 0
    }
}

// MARK: - Collector

struct CollectorBar: View {
    @EnvironmentObject var state: AppState
    private var targetedStore = State(initialValue: false)

    init() {}

    var body: some View {
        let targeted = targetedStore.wrappedValue
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 18))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                .symbolEffect(.bounce, value: state.collector.count)
                .scaleEffect(targeted ? 1.2 : 1)
            if state.collector.isEmpty {
                Text("Drag files and folders here to collect them, then move them to the Trash in one go.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.collector) { n in
                            chip(n).transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text(Fmt.bytes(state.collectedBytes))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Button("Clear") { state.clearCollector() }
                Button(role: .destructive) {
                    state.confirmTrash = true
                } label: {
                    Label("Move to Trash…", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(state.trashing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .animation(state.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: targeted)
        .animation(state.reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: state.collector.count)
        .onDrop(of: [UTType.fileURL], isTargeted: targetedStore.projectedValue) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url, url.isFileURL else { return }
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
            Image(nsImage: Icons.shared.icon(for: n)).resizable().frame(width: 16, height: 16)
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
