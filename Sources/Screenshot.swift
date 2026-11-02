// Dandelion - Screenshot: capture any part of the screen, mark it up, pin it, copy it, drag it anywhere.
// Capturing uses Apple's own `screencapture` tool (the same selection you get with Command-Shift-4),
// so it behaves exactly like macOS does. Markup is drawn by Dandelion and only ever saved where you choose.
// MIT License. See LICENSE.

import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case area, window, screen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .area: return "Capture Area"
            case .window: return "Capture Window"
            case .screen: return "Capture Screen"
            }
        }
        var symbol: String {
            switch self {
            case .area: return "rectangle.dashed"
            case .window: return "macwindow"
            case .screen: return "display"
            }
        }
        var shortcut: Hotkeys.Shortcut {
            switch self {
            case .area: return .captureArea
            case .window: return .captureWindow
            case .screen: return .captureScreen
            }
        }
    }

    @Published var recent: [URL] = []
    @Published var delay = 0
    @Published var capturing = false
    /// Keep Dandelion in the menu bar after its window closes, so the shortcuts keep working.
    @Published var inMenuBar: Bool {
        didSet { UserDefaults.standard.set(inMenuBar, forKey: "shotsInMenuBar") }
    }
    /// Shortcuts another app already owns.
    @Published var takenShortcuts: [Hotkeys.Shortcut] = []

    weak var app: AppState?

    static var folder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Pictures")
        return pictures.appendingPathComponent("Dandelion Screenshots", isDirectory: true)
    }

    init() {
        inMenuBar = UserDefaults.standard.bool(forKey: "shotsInMenuBar")
        refresh()
    }

    func start() {
        var taken: [Hotkeys.Shortcut] = []
        for mode in Mode.allCases {
            if !Hotkeys.shared.register(mode.shortcut, action: { [weak self] in
                MainActor.assumeIsolated { self?.capture(mode, fromShortcut: true) }
            }) {
                taken.append(mode.shortcut)
            }
        }
        takenShortcuts = taken
    }

    // MARK: capturing

    func capture(_ mode: Mode, fromShortcut: Bool = false) {
        guard !capturing else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            app?.alertMessage = "Dandelion needs permission to capture the screen. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. (macOS asks again after each update, because downloaded builds aren't notarized.)"
            return
        }
        capturing = true
        // keep Dandelion's own window out of full-screen shots taken from inside the app
        let hidApp = !fromShortcut && NSApp.isActive && mode != .area
        if hidApp { NSApp.hide(nil) }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dandelion-shot-\(UUID().uuidString).png")
        var args: [String] = []
        switch mode {
        case .area: args += ["-i", "-s"]
        case .window: args += ["-i", "-w", "-o"]
        case .screen: args += ["-m"]
        }
        if delay > 0 { args += ["-T", "\(delay)"] }
        args.append(tmp.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.terminationHandler = { _ in
            Task { @MainActor in
                self.capturing = false
                if hidApp { NSApp.unhide(nil) }
                self.finish(tmp)
            }
        }
        do {
            // a short pause so the window has gone before a full-screen shot
            if hidApp {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    do { try p.run() } catch {
                        self.capturing = false
                        NSApp.unhide(nil)
                    }
                }
            } else {
                try p.run()
            }
        } catch {
            capturing = false
            app?.alertMessage = "The screenshot couldn't start: \(error.localizedDescription)"
        }
    }

    /// Moves a fresh capture into the screenshots folder and opens it for markup. Cancelled captures leave no file.
    private func finish(_ tmp: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: tmp.path) else { return }
        do {
            try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let dest = uniqueURL(Self.folder.appendingPathComponent("Screenshot \(Self.stamp()).png"))
            try fm.moveItem(at: tmp, to: dest)
            refresh()
            openEditor(dest)
        } catch {
            app?.alertMessage = "The screenshot couldn't be saved: \(error.localizedDescription)"
        }
    }

    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: date)
    }

    private func uniqueURL(_ url: URL) -> URL {
        URL(fileURLWithPath: RulesEngine.uniquePath(url.path))
    }

    // MARK: the library

    func refresh() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let images = urls.filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
        let dated = images.map { u -> (URL, Date) in
            (u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        recent = dated.sorted { $0.1 > $1.1 }.prefix(48).map { $0.0 }
    }

    func openEditor(_ url: URL) {
        guard let editor = ShotEditor(url: url, model: self) else {
            app?.alertMessage = "That screenshot couldn't be opened."
            return
        }
        let host = NSHostingController(rootView: ShotEditorView(editor: editor))
        let size = editor.fittingWindowSize()
        editor.window = ExtraWindows.show(host, title: url.deletingPathExtension().lastPathComponent, size: size)
    }

    func copy(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        app?.show(Toast(text: "Copied the screenshot.", symbol: "doc.on.doc.fill", tint: Tool.screenshot.tint))
    }

    func pin(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        PinWindow.pin(image)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.folder)
    }

    func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            refresh()
        } catch {
            app?.alertMessage = "It couldn't be moved to the Trash: \(error.localizedDescription)"
        }
    }

    /// A small, fast thumbnail (never decodes the whole image).
    static func thumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

@MainActor
final class ShotEditor: ObservableObject {
    let url: URL
    let image: CGImage
    let nsImage: NSImage
    weak var model: ScreenshotModel?
    weak var window: NSWindow?

    @Published var marks: [Mark] = []
    @Published var draft: Mark?
    @Published var tool: MarkKind = .arrow
    @Published var color = 0
    @Published var textPrompt: CGPoint?
    @Published var textEntry = ""
    @Published var saved = true
    private var redoStack: [Mark] = []
    private(set) var pixelated: [UUID: CGImage] = [:]

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    init?(url: URL, model: ScreenshotModel) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.url = url
        self.image = cg
        self.model = model
        // points = pixels / 2 on Retina captures, so the window opens at a natural size
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        self.nsImage = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    func fittingWindowSize() -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let img = nsImage.size
        let maxW = screen.width * 0.8, maxH = screen.height * 0.8 - 90
        let s = min(1, maxW / max(img.width, 1), maxH / max(img.height, 1))
        return NSSize(width: max(640, img.width * s + 40), height: max(440, img.height * s + 110))
    }

    // MARK: drawing

    func begin(at p: CGPoint) {
        if tool == .text {
            textPrompt = p
            textEntry = ""
            return
        }
        draft = Mark(kind: tool, a: p, b: p, color: color)
    }

    func move(to p: CGPoint) {
        draft?.b = p
    }

    func end() {
        guard var m = draft else { return }
        draft = nil
        let r = m.rect
        if m.kind == .arrow {
            guard hypot(m.a.x - m.b.x, m.a.y - m.b.y) > 6 else { return }
        } else {
            guard r.width > 4, r.height > 4 else { return }
        }
        m.a = clamp(m.a); m.b = clamp(m.b)
        if m.kind == .blur, let piece = MarkDrawer.pixelate(image, rect: m.rect) { pixelated[m.id] = piece }
        add(m)
    }

    func commitText() {
        let text = textEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = textPrompt, !text.isEmpty {
            add(Mark(kind: .text, a: clamp(p), b: clamp(p), color: color, text: text))
        }
        textPrompt = nil
        textEntry = ""
    }

    private func add(_ m: Mark) {
        marks.append(m)
        redoStack.removeAll()
        saved = false
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), pixelSize.width), y: min(max(0, p.y), pixelSize.height))
    }

    var canUndo: Bool { !marks.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let m = marks.popLast() else { return }
        redoStack.append(m)
        saved = false
    }

    func redo() {
        guard let m = redoStack.popLast() else { return }
        marks.append(m)
        saved = false
    }

    func clear() {
        guard !marks.isEmpty else { return }
        redoStack = marks.reversed()
        marks.removeAll()
        saved = false
    }

    // MARK: output

    /// The screenshot with its markup, at full resolution.
    func rendered() -> CGImage? {
        MarkDrawer.render(image, marks: marks, pixelated: pixelated)
    }

    private func pngData() -> Data? {
        guard let cg = rendered() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    private func renderedNSImage() -> NSImage? {
        guard let cg = rendered() else { return nil }
        return NSImage(cgImage: cg, size: nsImage.size)
    }

    func copy() {
        guard let img = renderedNSImage() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        flash("Copied")
    }

    /// Saves the markup into the screenshot's file.
    func save() {
        guard let data = pngData() else { return }
        do {
            try data.write(to: url, options: .atomic)
            saved = true
            model?.refresh()
            flash("Saved")
        } catch {
            model?.app?.alertMessage = "The screenshot couldn't be saved: \(error.localizedDescription)"
        }
    }

    func saveAs() {
        guard let data = pngData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do { try data.write(to: dest, options: .atomic) } catch {
            model?.app?.alertMessage = "It couldn't be saved there: \(error.localizedDescription)"
        }
    }

    func pin() {
        guard let img = renderedNSImage() else { return }
        PinWindow.pin(img)
    }

    /// A file of the marked-up screenshot to drag into another app.
    func dragProvider() -> NSItemProvider {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Dandelion Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(url.lastPathComponent)
        if let data = pngData() { try? data.write(to: file, options: .atomic) }
        return NSItemProvider(contentsOf: file) ?? NSItemProvider()
    }

    @Published var flashText: String?
    private func flash(_ text: String) {
        flashText = text
        let t = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if self?.flashText == t { self?.flashText = nil }
        }
    }
}

// MARK: - pinned screenshots

/// A screenshot that floats above every window. Drag to move, scroll or pinch to resize, double-click or Esc to close.
final class PinWindow: NSPanel {
    private static var pinned: [PinWindow] = []

    static func pin(_ image: NSImage) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var size = image.size
        let maxSide: CGFloat = 520
        if max(size.width, size.height) > maxSide {
            let s = maxSide / max(size.width, size.height)
            size = NSSize(width: size.width * s, height: size.height * s)
        }
        let offset = CGFloat(pinned.count % 8) * 24
        let frame = NSRect(x: screen.maxX - size.width - 40 - offset, y: screen.maxY - size.height - 40 - offset,
                           width: size.width, height: size.height)
        let w = PinWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        w.isFloatingPanel = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.hasShadow = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.aspectRatio = size
        w.isReleasedWhenClosed = false
        let view = PinImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        pinned.append(w)
        w.orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { unpin() }

    func unpin() {
        orderOut(nil)
        PinWindow.pinned.removeAll { $0 === self }
    }

    func copyImage() {
        guard let img = (contentView as? NSImageView)?.image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}

private final class PinImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { (window as? PinWindow)?.unpin(); return }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        resize(by: 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04))
    }

    override func magnify(with event: NSEvent) {
        resize(by: 1 + event.magnification)
    }

    private func resize(by factor: CGFloat) {
        guard let w = window else { return }
        var f = w.frame
        let newW = min(max(f.width * factor, 80), 2400)
        let newH = newW * f.height / f.width
        f.origin.x += (f.width - newW) / 2
        f.origin.y += (f.height - newH) / 2
        f.size = NSSize(width: newW, height: newH)
        w.setFrame(f, display: true)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyPinned), keyEquivalent: "").target = self
        m.addItem(withTitle: "Close", action: #selector(closePinned), keyEquivalent: "").target = self
        return m
    }

    @objc private func copyPinned() { (window as? PinWindow)?.copyImage() }
    @objc private func closePinned() { (window as? PinWindow)?.unpin() }
}
