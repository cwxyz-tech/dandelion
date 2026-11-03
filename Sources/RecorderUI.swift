// Dandelion - the Screen Recorder screens: choose what to record, record it, then style and export it.
// MIT License. See LICENSE.
//
// View state lives in the model (no @State): in the macOS 26 SDK @State is a macro, and the
// Command Line Tools don't ship the plugin that expands it.

import AppKit
import Darwin
import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct RecordingItem: Identifiable, Equatable {
    var id: String { raw.path }
    let raw: URL
    var info: RecordingInfo
    var infoURL: URL { raw.deletingPathExtension().appendingPathExtension("json") }
    var title: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: info.created)
    }
}

@MainActor
final class RecorderModel: ObservableObject {
    enum Phase { case setup, recording, editing }
    enum Source: String, CaseIterable, Identifiable {
        case screen, window, area
        var id: String { rawValue }
        var title: String {
            switch self {
            case .screen: return "Whole Screen"
            case .window: return "A Window"
            case .area: return "An Area"
            }
        }
        var symbol: String {
            switch self {
            case .screen: return "display"
            case .window: return "macwindow"
            case .area: return "rectangle.dashed"
            }
        }
    }

    struct WindowChoice: Identifiable, Equatable {
        let id: CGWindowID
        let title: String
        let app: String
        let bundleID: String
        let size: CGSize
    }

    @Published var phase: Phase = .setup
    @Published var source: Source = .screen { didSet { if source == .window { loadWindows() } } }
    @Published var mic: Bool { didSet { UserDefaults.standard.set(mic, forKey: "recorderMic") } }
    @Published var windows: [WindowChoice] = []
    @Published var pickedWindow: CGWindowID?
    @Published var elapsed: Double = 0
    @Published var starting = false
    /// True while a stopped recording is being finished and saved.
    @Published var saving = false
    @Published var recordings: [RecordingItem] = []
    @Published var current: RecordingItem?
    @Published var style = ExportStyle() { didSet { schedulePreview() } }
    @Published var previewTime: Double = 0 { didSet { schedulePreview() } }
    @Published var preview: NSImage?
    @Published var exporting = false
    @Published var exportProgress = 0.0
    @Published var lastExport: URL?

    weak var app: AppState?
    private var session: CaptureSession?
    private var tracker: PointerTracker?
    private var clock: Timer?
    private var startedAt = Date()
    private var previewTask: Task<Void, Never>?
    private var captureSize = CGSize.zero

    static var library: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Dandelion", isDirectory: true).appendingPathComponent("Recordings", isDirectory: true)
    }

    static var exports: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Movies")
        return movies.appendingPathComponent("Dandelion Recordings", isDirectory: true)
    }

    init() {
        mic = UserDefaults.standard.bool(forKey: "recorderMic")
    }

    /// Raw recordings can show anything that was on screen, so their folder is readable only by you.
    static func makeLibrary() throws {
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        chmod(library.path, 0o700)
    }

    func start() {
        Hotkeys.shared.register(.record) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        // the library (with every recording's cursor trail) is only read when the Recorder is opened
    }

    private var libraryLoaded = false
    func loadLibraryIfNeeded() {
        guard !libraryLoaded else { return }
        libraryLoaded = true
        loadLibrary()
    }

    var isRecording: Bool { phase == .recording }

    func toggle() {
        if phase == .recording { stop() } else if !starting && !saving { begin(fromShortcut: true) }
    }

    // MARK: choosing a window

    func loadWindows() {
        Task { @MainActor in
            guard CGPreflightScreenCaptureAccess() else { return }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            let me = Bundle.main.bundleIdentifier
            windows = content.windows
                .filter { w in
                    w.windowLayer == 0 && w.frame.width >= 160 && w.frame.height >= 100 && w.owningApplication?.bundleIdentifier != me
                        && w.owningApplication != nil
                }
                .map { w in
                    WindowChoice(id: w.windowID, title: (w.title?.isEmpty == false ? w.title! : (w.owningApplication?.applicationName ?? "Window")),
                                 app: w.owningApplication?.applicationName ?? "", bundleID: w.owningApplication?.bundleIdentifier ?? "",
                                 size: w.frame.size)
                }
                .sorted { $0.app != $1.app ? $0.app.localizedCaseInsensitiveCompare($1.app) == .orderedAscending : $0.title < $1.title }
            if let p = pickedWindow, !windows.contains(where: { $0.id == p }) { pickedWindow = nil }
        }
    }

    // MARK: recording

    func begin(fromShortcut: Bool = false) {
        guard phase != .recording, !starting, !saving else { return }
        // a shortcut can't record a window nobody picked yet; record the screen instead
        if fromShortcut && source == .window && pickedWindow == nil { source = .screen }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            if fromShortcut { app?.bringToFront(tool: .recorder) }
            app?.alertMessage = "Dandelion needs permission to record the screen. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. (macOS asks again after each update, because downloaded builds aren't notarized.)"
            return
        }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            do { try await beginRecording() } catch {
                NSApp.unhide(nil)
                app?.alertMessage = "The recording couldn't start: \(error.localizedDescription)"
                cleanUpAfterStop()
            }
        }
    }

    private func beginRecording() async throws {
        var useMic = mic
        if useMic {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined: useMic = await AVCaptureDevice.requestAccess(for: .audio)
            default: useMic = false
            }
            if !useMic {
                app?.show(Toast(text: "Recording without the microphone (no permission).", symbol: "mic.slash.fill", tint: .orange))
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = Bundle.main.bundleIdentifier
        let mine = content.windows.filter { $0.owningApplication?.bundleIdentifier == me }

        var filter: SCContentFilter
        var region: CGRect
        var sourceRect: CGRect?
        var scale: CGFloat = 2

        func display(for screen: NSScreen) -> SCDisplay? {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            return content.displays.first { $0.displayID == id } ?? content.displays.first
        }

        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]

        switch source {
        case .window where pickedWindow != nil:
            guard let w = content.windows.first(where: { $0.windowID == pickedWindow }) else {
                throw RecorderError.message("That window isn't open anymore. Pick another one.")
            }
            filter = SCContentFilter(desktopIndependentWindow: w)
            region = w.frame
            let center = CGPoint(x: w.frame.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - w.frame.midY)
            scale = (NSScreen.screens.first { NSPointInRect(center, $0.frame) } ?? mouseScreen).backingScaleFactor
        case .area:
            NSApp.hide(nil)
            guard let picked = await AreaPicker.pick() else { NSApp.unhide(nil); return }
            let (screen, rect) = picked
            guard let d = display(for: screen) else { throw RecorderError.message("No display found.") }
            filter = SCContentFilter(display: d, excludingWindows: mine)
            let bounds = CGDisplayBounds(d.displayID)
            sourceRect = rect
            region = CGRect(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY, width: rect.width, height: rect.height)
            scale = screen.backingScaleFactor
        default:
            guard let d = display(for: mouseScreen) else { throw RecorderError.message("No display found.") }
            filter = SCContentFilter(display: d, excludingWindows: mine)
            region = CGDisplayBounds(d.displayID)
            scale = mouseScreen.backingScaleFactor
        }

        // keep 4K-and-up screens at a size the encoder handles comfortably
        var pixels = CGSize(width: region.width * scale, height: region.height * scale)
        let longest = max(pixels.width, pixels.height)
        if longest > 3840 { pixels = CGSize(width: pixels.width * 3840 / longest, height: pixels.height * 3840 / longest) }

        try Self.makeLibrary()
        let raw = Self.library.appendingPathComponent("Recording \(ScreenshotModel.stamp()).mov")
        let session = CaptureSession(url: raw, filter: filter, sourceRect: sourceRect, pixelSize: pixels, mic: useMic)
        let tracker = PointerTracker(region: region)
        session.onFirstFrame = { host in
            Task { @MainActor in tracker.setStart(hostSeconds: host) }
        }
        session.onError = { message in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .recording else { return }
                self.app?.alertMessage = "The recording stopped: \(message)"
                self.stop()
            }
        }
        NSApp.hide(nil)   // also after picking an area, since showing the picker brings Dandelion back
        try? await Task.sleep(nanoseconds: 300_000_000)
        tracker.start()
        try await session.start()
        self.session = session
        self.tracker = tracker
        captureSize = session.pixelSize
        startedAt = Date()
        elapsed = 0
        phase = .recording
        dandelionIsRecording = true
        app?.recordingNow = true
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.elapsed = Date().timeIntervalSince(self.startedAt) }
        }
    }

    func stop() {
        guard phase == .recording, let session, let tracker else { return }
        tracker.stop()
        clock?.invalidate()
        clock = nil
        phase = .setup
        saving = true
        Task { @MainActor in
            let length = await session.stop()
            saving = false
            cleanUpAfterStop()
            chmod(session.url.path, 0o600)
            app?.bringToFront(tool: .recorder)
            guard length > 0.3 else {
                try? FileManager.default.removeItem(at: session.url)
                app?.alertMessage = "The recording was too short or couldn't be saved."
                return
            }
            let info = RecordingInfo(duration: length, width: Int(captureSize.width), height: Int(captureSize.height),
                                     cursor: tracker.samples, clicks: tracker.clicks, hasAudio: session.hasAudio, created: Date())
            let item = RecordingItem(raw: session.url, info: info)
            save(item)
            loadLibraryIfNeeded()
            recordings.removeAll { $0 == item }
            recordings.insert(item, at: 0)
            edit(item)
        }
    }

    private func cleanUpAfterStop() {
        session = nil
        tracker = nil
        dandelionIsRecording = false
        app?.recordingNow = false
    }

    // MARK: the library

    private func save(_ item: RecordingItem) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(item.info) {
            try? data.write(to: item.infoURL, options: .atomic)
            chmod(item.infoURL.path, 0o600)
        }
    }

    func loadLibrary() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.library, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        recordings = files.filter { $0.pathExtension == "mov" }.compactMap { raw in
            let json = raw.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: json), let info = try? dec.decode(RecordingInfo.self, from: data) else { return nil }
            return RecordingItem(raw: raw, info: info)
        }
        .sorted { $0.info.created > $1.info.created }
    }

    func delete(_ item: RecordingItem) {
        // both go to the Trash together, so putting the recording back brings its cursor trail too
        try? FileManager.default.trashItem(at: item.raw, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: item.infoURL, resultingItemURL: nil)
        recordings.removeAll { $0 == item }
        if current == item { current = nil; phase = .setup }
    }

    // MARK: editing and export

    func edit(_ item: RecordingItem) {
        current = item
        lastExport = nil
        exportProgress = 0
        phase = .editing
        previewTime = item.info.clicks.first.map { min($0.t + 0.4, item.info.duration) } ?? item.info.duration / 2
    }

    func backToSetup() {
        phase = .setup
        current = nil
        preview = nil
    }

    private func schedulePreview() {
        guard phase == .editing, let item = current else { return }
        previewTask?.cancel()
        let style = self.style, t = previewTime
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            if Task.isCancelled { return }
            let cg = await RecordingExporter.previewFrame(raw: item.raw, info: item.info, style: style, at: t)
            if Task.isCancelled { return }
            if let cg { preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }

    func export() {
        guard let item = current, !exporting else { return }
        exporting = true
        exportProgress = 0
        lastExport = nil
        let out = Self.exports.appendingPathComponent(item.raw.deletingPathExtension().lastPathComponent + ".mp4")
        let style = self.style
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: Self.exports, withIntermediateDirectories: true)
                let dest = URL(fileURLWithPath: RulesEngine.uniquePath(out.path))
                try await RecordingExporter.export(raw: item.raw, info: item.info, style: style, to: dest) { p in
                    Task { @MainActor in self.exportProgress = p }
                }
                lastExport = dest
                app?.show(Toast(text: "Exported to Movies → Dandelion Recordings.", symbol: "checkmark.circle.fill", tint: Tool.recorder.tint))
            } catch {
                app?.alertMessage = "The export didn't finish: \(error.localizedDescription)"
            }
            exporting = false
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - screens

struct RecorderView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .setup: RecSetupView().transition(.opacity)
            case .recording: RecRecordingView().transition(.opacity)
            case .editing: RecEditView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }
}

struct RecSetupView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ToolHeader(tool: .recorder, subtitle: "Screen recordings that zoom in smoothly wherever you click.")
                HStack(spacing: 14) {
                    ForEach(RecorderModel.Source.allCases) { s in sourceButton(s) }
                }
                if model.source == .window { windowPicker }
                HStack(spacing: 12) {
                    Image(systemName: model.mic ? "mic.fill" : "mic.slash").foregroundStyle(.secondary).frame(width: 18)
                    Text("Record the microphone").font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.mic }, set: { model.mic = $0 })).toggleStyle(.switch).labelsHidden()
                }
                .padding(14)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 14) {
                    Button { model.begin() } label: {
                        Label(model.starting ? "Starting…" : "Start Recording", systemImage: "record.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tool.recorder.tint)
                    .controlSize(.large)
                    .disabled(model.starting || model.saving || (model.source == .window && model.pickedWindow == nil))
                    Text("Stop with ⌥⇧6 or the menu bar. Shortcut ⌥⇧6 also starts a recording from any app.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                library
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.loadLibraryIfNeeded() }
    }

    private func sourceButton(_ s: RecorderModel.Source) -> some View {
        let on = model.source == s
        return Button { model.source = s } label: {
            VStack(spacing: 8) {
                Image(systemName: s.symbol).font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Tool.recorder.tint)
                    .frame(height: 30)
                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(on ? Color.white : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(on ? AnyShapeStyle(Tool.recorder.tint) : AnyShapeStyle(Color.primary.opacity(0.05)), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pick a window").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.loadWindows() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            VStack(spacing: 0) {
                if model.windows.isEmpty {
                    Text(CGPreflightScreenCaptureAccess() ? "No windows found. Open the app you want to record, then refresh."
                         : "Allow screen recording first (press Start Recording once), then refresh.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                }
                ForEach(model.windows) { w in
                    Button { model.pickedWindow = w.id } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: TimeTrackerModel.icon(for: w.bundleID)).resizable().frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text("\(w.app) · \(Int(w.size.width)) × \(Int(w.size.height))").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.pickedWindow == w.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tool.recorder.tint)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(model.pickedWindow == w.id ? Tool.recorder.tint.opacity(0.1) : Color.clear)
                }
            }
            .frame(maxHeight: 260)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var library: some View {
        if !model.recordings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recordings").font(.system(size: 15, weight: .semibold)).padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(model.recordings) { r in
                        HStack(spacing: 10) {
                            Image(systemName: "film").foregroundStyle(Tool.recorder.tint).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).font(.system(size: 13, weight: .medium))
                                Text("\(RecorderModel.format(r.info.duration)) · \(r.info.clicks.count) click\(r.info.clicks.count == 1 ? "" : "s")\(r.info.hasAudio ? " · with sound" : "")")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit & Export") { model.edit(r) }
                            Button { model.delete(r) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Move the raw recording to the Trash")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        Divider().padding(.leading, 44)
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

struct RecRecordingView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "record.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Tool.recorder.tint)
                .symbolEffect(.pulse)
            Text(RecorderModel.format(model.elapsed)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
            Text("Recording. Dandelion's own windows are left out of the video.").foregroundStyle(.secondary)
            Button { model.stop() } label: {
                Label("Stop Recording", systemImage: "stop.fill").padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Tool.recorder.tint)
            .controlSize(.large)
            .keyboardShortcut(.escape, modifiers: [])
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecEditView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Button { model.backToSetup() } label: { Label("All Recordings", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                    if let c = model.current {
                        Text("\(RecorderModel.format(c.info.duration)) · \(c.info.clicks.count) click\(c.info.clicks.count == 1 ? "" : "s")")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                ZStack {
                    Color.primary.opacity(0.05)
                    if let p = model.preview {
                        Image(nsImage: p).resizable().aspectRatio(contentMode: .fit)
                            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if let c = model.current {
                    HStack(spacing: 10) {
                        Text(RecorderModel.format(model.previewTime)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                        Slider(value: Binding(get: { model.previewTime }, set: { model.previewTime = $0 }), in: 0...max(0.1, c.info.duration))
                        Text(RecorderModel.format(c.info.duration)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text("Drag to preview any moment. The zoom follows your clicks.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(20)
            Divider()
            ScrollView { controls.padding(20) }
                .frame(width: 300)
        }
    }

    private var controls: some View {
        let s = Binding(get: { model.style }, set: { model.style = $0 })
        return VStack(alignment: .leading, spacing: 18) {
            group("Background") {
                Toggle("Frame the recording", isOn: s.framed)
                if model.style.framed {
                    HStack(spacing: 8) {
                        ForEach(Array(Backdrops.presets.enumerated()), id: \.offset) { i, p in
                            Button { model.style.background = i } label: {
                                Circle()
                                    .fill(LinearGradient(colors: [Color(red: p.a.0, green: p.a.1, blue: p.a.2), Color(red: p.b.0, green: p.b.1, blue: p.b.2)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(Color.primary.opacity(model.style.background == i ? 0.8 : 0.12), lineWidth: model.style.background == i ? 2.5 : 1))
                            }
                            .buttonStyle(.plain)
                            .help(p.name)
                        }
                    }
                    slider("Padding", s.padding, 0...0.2)
                    slider("Rounded corners", s.corner, 0...0.05)
                }
            }
            group("Zoom") {
                Toggle("Zoom in on clicks", isOn: s.zoom)
                if model.style.zoom { slider("Zoom amount", s.zoomAmount, 1.2...3) }
            }
            group("Cursor") {
                Toggle("Show the cursor", isOn: s.showCursor)
                if model.style.showCursor { slider("Cursor size", s.cursorScale, 0.8...3) }
                Toggle("Ripple on each click", isOn: s.ripples)
            }
            group("Export") {
                Picker("Size", selection: s.height) {
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                    Text("1440p").tag(1440)
                    Text("4K").tag(2160)
                }
                if model.exporting {
                    ProgressView(value: model.exportProgress) { Text("Exporting… \(Int(model.exportProgress * 100))%").font(.system(size: 11)) }
                } else {
                    Button { model.export() } label: {
                        Label("Export Video", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tool.recorder.tint)
                    .controlSize(.large)
                }
                if let out = model.lastExport {
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                        Button("Play") { NSWorkspace.shared.open(out) }
                    }
                    Text(out.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12))
            Slider(value: value, in: range)
        }
    }
}
