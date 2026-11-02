// Dandelion - the Duplicate Finder screens.
// MIT License. See LICENSE.
//
// View state is stored with State(...) directly instead of the @State attribute: in the macOS 26 SDK
// @State is a macro, and the Command Line Tools don't ship the plugin that expands it.

import AppKit
import QuickLookThumbnailing
import SwiftUI

@MainActor
final class DuplicatesModel: ObservableObject {
    enum Phase { case setup, scanning, results }

    @Published var phase: Phase = .setup
    @Published var folders: [String]
    @Published var minimum: Int64 = 1_000_000
    @Published var includeHidden = false
    @Published var groups: [DupGroup] = []
    /// Paths chosen to go to the Trash.
    @Published var selected: Set<String> = []
    @Published var keepRule: DuplicateFinder.KeepRule = .oldest
    @Published var filter: FileKind?
    @Published var live = DupProgress.Snapshot()
    @Published var elapsed: Double = 0
    @Published var confirmTrash = false
    @Published var trashing = false

    weak var app: AppState?
    private var progress: DupProgress?
    private var timer: Timer?

    static let sizes: [(String, Int64)] = [("Any size", 1), ("100 KB", 100_000), ("1 MB", 1_000_000), ("10 MB", 10_000_000), ("100 MB", 100_000_000)]

    init() {
        let home = NSHomeDirectory()
        folders = ["Downloads", "Desktop", "Documents", "Pictures", "Movies", "Music"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: folders

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to search for duplicates"
        guard panel.runModal() == .OK else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
        }
    }

    func remove(_ folder: String) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) { folders.removeAll { $0 == folder } }
    }

    // MARK: scanning

    func scan() {
        guard !folders.isEmpty else { return }
        let prog = DupProgress()
        progress = prog
        live = DupProgress.Snapshot()
        elapsed = 0
        groups = []
        selected = []
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { phase = .scanning }
        let began = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard self.progress === prog else { return }
                self.live = prog.snapshot()
                self.elapsed = Date().timeIntervalSince(began)
            }
        }
        let roots = folders
        let options = DuplicateFinder.Options(minimumLength: minimum, includeHidden: includeHidden)
        Task.detached(priority: .userInitiated) {
            let found = DuplicateFinder.find(in: roots, options: options, progress: prog)
            await self.finish(found, prog)
        }
    }

    private func finish(_ found: [DupGroup], _ prog: DupProgress) {
        guard progress === prog else { return }
        timer?.invalidate()
        timer = nil
        if prog.cancelled {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { phase = .setup }
            return
        }
        groups = found
        autoSelect()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { phase = .results }
    }

    func cancel() {
        progress?.cancel()
        timer?.invalidate()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { phase = .setup }
    }

    func startOver() {
        groups = []
        selected = []
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { phase = .setup }
    }

    // MARK: choosing

    var visibleGroups: [DupGroup] {
        guard let f = filter else { return groups }
        return groups.filter { g in
            var k = FileKind.of(name: g.files.first?.name ?? "")
            if k == .screenshot { k = .image }
            return f == .other ? ![.image, .video, .audio, .document].contains(k) : k == f
        }
    }

    var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }

    /// Selected files the current filter is hiding (they'd still go to the Trash).
    var hiddenSelectedCount: Int {
        guard filter != nil else { return 0 }
        let shown = Set(visibleGroups.flatMap { $0.files.map { $0.path } })
        return selected.filter { !shown.contains($0) }.count
    }

    var selectedBytes: Int64 {
        groups.reduce(0) { t, g in t + g.files.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size } }
    }

    /// Selects every copy except the one the keep rule picks.
    func autoSelect() {
        var s = Set<String>()
        for g in groups {
            guard let keep = DuplicateFinder.keeper(g, rule: keepRule) else { continue }
            for f in g.files where f.path != keep.path { s.insert(f.path) }
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selected = s }
    }

    func clearSelection() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selected = [] }
    }

    /// Toggles one file. At least one copy in each set always stays unselected, so nothing is lost by accident.
    func toggle(_ f: DupFile, in g: DupGroup) {
        if selected.contains(f.path) {
            selected.remove(f.path)
        } else {
            let others = g.files.filter { $0.path != f.path && !selected.contains($0.path) }
            if others.isEmpty {
                app?.show(Toast(text: "One copy always stays, so you never lose the file.", symbol: "hand.raised.fill", tint: .orange))
                NSSound.beep()
                return
            }
            selected.insert(f.path)
        }
    }

    // MARK: the Trash

    func trashSelected() {
        guard !selected.isEmpty, !trashing else { return }
        let plan: [(DupFile, [DupFile])] = groups.flatMap { g -> [(DupFile, [DupFile])] in
            let keepers = g.files.filter { !selected.contains($0.path) }
            return g.files.filter { selected.contains($0.path) }.map { ($0, keepers) }
        }
        trashing = true
        Task.detached(priority: .userInitiated) {
            var moved: [String] = []
            var problems: [String] = []
            for (file, keepers) in plan {
                // the copy being kept has to still be there, untouched, or this one stays too
                guard keepers.contains(where: { DuplicateFinder.verify($0) == nil }) else {
                    problems.append("Kept \u{201C}\(DisplayName.clean(file.name))\u{201D}: the copy you're keeping changed or moved.")
                    continue
                }
                if let reason = Safety.protectionReason(path: file.path, title: DisplayName.clean(file.name)) ?? DuplicateFinder.verify(file) {
                    problems.append(reason)
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
                    moved.append(file.path)
                } catch {
                    problems.append("\(DisplayName.clean(file.name)): \(error.localizedDescription)")
                }
            }
            await self.finishTrash(moved: moved, problems: problems)
        }
    }

    private func finishTrash(moved: [String], problems: [String]) {
        trashing = false
        let gone = Set(moved)
        let freed = groups.flatMap { $0.files }.filter { gone.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size }
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
            groups = groups.compactMap { g in
                var g = g
                g.files.removeAll { gone.contains($0.path) }
                return g.files.count > 1 ? g : nil
            }
            selected.subtract(gone)
            selected = selected.filter { p in groups.contains { $0.files.contains { $0.path == p } } }
        }
        if !moved.isEmpty {
            let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif"
            if FileManager.default.fileExists(atPath: path) { NSSound(contentsOfFile: path, byReference: true)?.play() }
            app?.show(Toast(text: "Moved \(moved.count == 1 ? "1 duplicate" : "\(moved.count) duplicates") to the Trash · \(Fmt.bytes(freed)) back once you empty it",
                            symbol: "trash.fill", tint: .green))
        }
        if !problems.isEmpty {
            app?.alertMessage = (moved.isEmpty ? "Nothing was moved:" : "Some files were kept:") + "\n\n" + problems.joined(separator: "\n")
        }
    }

    func reveal(_ f: DupFile) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
    func quickLook(_ f: DupFile) { app?.quickLookURL = URL(fileURLWithPath: f.path) }
}

/// Small cached thumbnails (photos and videos show their picture; everything else its icon).
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []

    func image(_ path: String) -> NSImage? { cache[path] }

    func load(_ path: String, side: CGFloat, done: @escaping (NSImage) -> Void) {
        if let img = cache[path] { done(img); return }
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: side, height: side),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async {
                self.cache[path] = img
                self.order.append(path)
                if self.order.count > 300 { self.cache[self.order.removeFirst()] = nil }
                done(img)
            }
        }
    }
}

struct Thumb: View {
    let path: String
    let side: CGFloat
    private var imgStore = State(initialValue: NSImage?.none)

    init(path: String, side: CGFloat) {
        self.path = path
        self.side = side
    }

    var body: some View {
        ZStack {
            if let img = imgStore.wrappedValue ?? Thumbnails.shared.image(path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            } else {
                Image(nsImage: Icons.shared.icon(forPath: path)).resizable().padding(side * 0.12)
            }
        }
        .frame(width: side, height: side)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: side * 0.16))
        .onAppear {
            Thumbnails.shared.load(path, side: side) { img in
                withAnimation(.easeOut(duration: 0.2)) { imgStore.wrappedValue = img }
            }
        }
    }
}

struct DuplicatesView: View {
    @EnvironmentObject var model: DuplicatesModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .setup: DupSetupView().transition(.opacity.combined(with: .scale(scale: 0.985)))
            case .scanning: DupScanningView().transition(.opacity.combined(with: .scale(scale: 1.02)))
            case .results: DupResultsView().transition(.opacity)
            }
        }
    }
}

struct DupSetupView: View {
    @EnvironmentObject var model: DuplicatesModel
    private var shownStore = State(initialValue: false)
    init() {}

    var body: some View {
        let shown = shownStore.wrappedValue
        VStack(spacing: 20) {
            Spacer(minLength: 10)
            ToolHeader(tool: .duplicates, subtitle: "Find identical files hiding in your folders, and keep just one of each.")
                .frame(maxWidth: 620)
            VStack(alignment: .leading, spacing: 8) {
                Text("Look in").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(model.folders.enumerated()), id: \.element) { i, f in
                        HStack(spacing: 10) {
                            Image(nsImage: Icons.shared.icon(forPath: f)).resizable().frame(width: 22, height: 22)
                            Text(FileManager.default.displayName(atPath: f)).font(.system(size: 13, weight: .medium))
                            Text((f as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            Spacer()
                            Button { model.remove(f) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                                .help("Don't look in this folder")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 8)
                        .animation(model.reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8).delay(Double(i) * 0.03), value: shown)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        if i < model.folders.count - 1 { Divider().padding(.leading, 44) }
                    }
                    if model.folders.isEmpty {
                        Text("Add at least one folder to search.").font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                Button { model.addFolders() } label: { Label("Add Folders…", systemImage: "plus") }
            }
            .frame(maxWidth: 620)
            HStack(spacing: 16) {
                Text("Ignore files smaller than").font(.system(size: 12))
                Picker("", selection: Binding(get: { model.minimum }, set: { model.minimum = $0 })) {
                    ForEach(DuplicatesModel.sizes, id: \.1) { s in Text(s.0).tag(s.1) }
                }
                .labelsHidden()
                .frame(width: 120)
                Toggle("Include hidden files", isOn: Binding(get: { model.includeHidden }, set: { model.includeHidden = $0 }))
                    .font(.system(size: 12))
                Spacer()
            }
            .frame(maxWidth: 620)
            Button { model.scan() } label: {
                Label("Find Duplicates", systemImage: "sparkle.magnifyingglass").padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.folders.isEmpty)
            .keyboardShortcut(.defaultAction)
            Text("App bundles and photo libraries are never opened up, so nothing inside them can be broken.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if model.reduceMotion { shownStore.wrappedValue = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { shownStore.wrappedValue = true }
        }
    }
}

struct DupScanningView: View {
    @EnvironmentObject var model: DuplicatesModel

    var body: some View {
        let s = model.live
        VStack(spacing: 18) {
            Spacer()
            ScanSpinner(reduce: model.reduceMotion).frame(width: 150, height: 150)
            Text(s.stage + "…").font(.system(size: 20, weight: .semibold)).contentTransition(.opacity)
            HStack(spacing: 28) {
                stat(Fmt.count(s.files), "files looked at")
                stat(Fmt.count(s.candidates), "worth comparing")
                stat(Fmt.duration(model.elapsed), "elapsed")
            }
            .animation(model.reduceMotion ? nil : .snappy(duration: 0.2), value: s.files)
            if s.bytesToHash > 0 {
                ProgressView(value: Double(min(s.hashedBytes, s.bytesToHash)), total: Double(max(1, s.bytesToHash)))
                    .frame(maxWidth: 360)
                    .animation(model.reduceMotion ? nil : .easeOut(duration: 0.2), value: s.hashedBytes)
            }
            Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).controlSize(.large)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 110)
    }
}

struct DupResultsView: View {
    @EnvironmentObject var model: DuplicatesModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(.green)
                        .symbolEffect(.bounce, value: model.groups.isEmpty)
                    Text("No duplicates found").font(.system(size: 20, weight: .semibold))
                    Text("Every file in those folders is one of a kind.").foregroundStyle(.secondary)
                    Button("Search Again") { model.startOver() }.controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(model.visibleGroups.enumerated()), id: \.element.id) { i, g in
                            DupGroupCard(group: g, index: i)
                        }
                    }
                    .padding(16)
                }
                Divider()
                bottomBar
            }
        }
        .overlay {
            if model.trashing {
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
        .alert("Move \(model.selected.count == 1 ? "1 duplicate" : "\(model.selected.count) duplicates") to the Trash?",
               isPresented: Binding(get: { model.confirmTrash }, set: { model.confirmTrash = $0 })) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let hidden = model.hiddenSelectedCount
            Text((hidden > 0 ? "\(Fmt.count(hidden)) of them \(hidden == 1 ? "isn't" : "aren't") shown with the current filter. " : "")
                 + "That's \(Fmt.bytes(model.selectedBytes)). One copy of every file stays where it is. Each file is checked first to make sure it hasn't changed, and you can put things back from the Trash until you empty it.")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.groups.isEmpty ? "All clear" : "\(Fmt.count(model.groups.count)) sets of duplicates")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("\(Fmt.bytes(model.totalReclaimable)) could be freed by keeping one of each")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button { model.startOver() } label: { Label("New Search", systemImage: "arrow.counterclockwise") }
            }
            if !model.groups.isEmpty {
                HStack(spacing: 10) {
                    Picker("", selection: Binding(get: { model.filter }, set: { v in withAnimation { model.filter = v } })) {
                        Text("All").tag(FileKind?.none)
                        Text("Images").tag(FileKind?.some(.image))
                        Text("Videos").tag(FileKind?.some(.video))
                        Text("Audio").tag(FileKind?.some(.audio))
                        Text("Documents").tag(FileKind?.some(.document))
                        Text("Other").tag(FileKind?.some(.other))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    Spacer()
                    Picker("", selection: Binding(get: { model.keepRule }, set: { model.keepRule = $0; model.autoSelect() })) {
                        ForEach(DuplicateFinder.KeepRule.allCases) { r in Text(r.rawValue).tag(r) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .help("Which copy to keep when selecting duplicates")
                    Button("Select Duplicates") { model.autoSelect() }
                    Button("Clear") { model.clearSelection() }.disabled(model.selected.isEmpty)
                }
            }
        }
        .padding(16)
        .animation(model.reduceMotion ? nil : .snappy(duration: 0.25), value: model.totalReclaimable)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill").foregroundStyle(model.selected.isEmpty ? Color.secondary : Color.red)
                .symbolEffect(.bounce, value: model.selected.count)
            Text(model.selected.isEmpty ? "Nothing selected" : "\(Fmt.count(model.selected.count)) selected · \(Fmt.bytes(model.selectedBytes))")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer()
            Button(role: .destructive) { model.confirmTrash = true } label: { Label("Move to Trash…", systemImage: "trash") }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.selected.isEmpty || model.trashing)
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .animation(model.reduceMotion ? nil : .snappy(duration: 0.2), value: model.selected.count)
    }
}

struct DupGroupCard: View {
    @EnvironmentObject var model: DuplicatesModel
    let group: DupGroup
    let index: Int
    private var shownStore = State(initialValue: false)

    init(group: DupGroup, index: Int) {
        self.group = group
        self.index = index
    }

    var body: some View {
        let shown = shownStore.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Thumb(path: group.files[0].path, side: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayName.clean(group.files[0].name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(group.files.count) copies · \(Fmt.bytes(group.length)) each")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Fmt.bytes(group.reclaimable)) extra")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Tool.duplicates.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Tool.duplicates.tint.opacity(0.12), in: Capsule())
            }
            .padding(12)
            Divider()
            ForEach(group.files) { f in
                DupFileRow(file: f, group: group)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 14)
        .onAppear {
            if model.reduceMotion || index > 20 { shownStore.wrappedValue = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(Double(index) * 0.035)) { shownStore.wrappedValue = true }
        }
    }
}

struct DupFileRow: View {
    @EnvironmentObject var model: DuplicatesModel
    let file: DupFile
    let group: DupGroup

    private static let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        let picked = model.selected.contains(file.path)
        HStack(spacing: 10) {
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(picked ? Color.red : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(DisplayName.clean(file.name)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .strikethrough(picked, color: .red)
                Text(DisplayName.clean((file.folder as NSString).abbreviatingWithTildeInPath))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Self.dates.string(from: file.modified)).font(.system(size: 10)).foregroundStyle(.tertiary)
            if !picked {
                Text("KEEP")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(picked ? Color.red.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(model.reduceMotion ? nil : .snappy(duration: 0.2)) { model.toggle(file, in: group) }
        }
        .contextMenu {
            Button("Quick Look") { model.quickLook(file) }
            Button("Reveal in Finder") { model.reveal(file) }
        }
        .help(DisplayName.clean(file.path))
    }
}
