// Dandelion - the Screenshot screens: the tool page and the markup editor.
// MIT License. See LICENSE.
//
// View state lives in the models (no @State): in the macOS 26 SDK @State is a macro, and the
// Command Line Tools don't ship the plugin that expands it.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScreenshotView: View {
    @EnvironmentObject var model: ScreenshotModel

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ToolHeader(tool: .screenshot, subtitle: "Capture any part of the screen, mark it up, and keep it handy.")
                HStack(spacing: 14) {
                    ForEach(ScreenshotModel.Mode.allCases) { mode in captureButton(mode) }
                }
                optionsCard
                library
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.refresh() }
    }

    private func captureButton(_ mode: ScreenshotModel.Mode) -> some View {
        Button { model.capture(mode) } label: {
            VStack(spacing: 10) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Tool.screenshot.tint)
                    .frame(height: 32)
                Text(mode.title).font(.system(size: 13, weight: .semibold))
                Text(model.takenShortcuts.contains(mode.shortcut) ? "Shortcut in use by another app" : mode.shortcut.label)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(model.capturing)
        .help("\(mode.title) (\(mode.shortcut.label) from any app)")
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "timer").foregroundStyle(.secondary)
                Text("Delay").font(.system(size: 13))
                Picker("", selection: Binding(get: { model.delay }, set: { model.delay = $0 })) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                .labelsHidden()
                .frame(width: 130)
                Spacer()
                Button { model.openFolder() } label: { Label("Open Folder", systemImage: "folder") }
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "menubar.rectangle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep shortcuts working after closing the window").font(.system(size: 13))
                    Text("Dandelion stays in the menu bar, so ⌥⇧3, ⌥⇧4 and ⌥⇧5 work from any app.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.inMenuBar }, set: { model.inMenuBar = $0 }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent").font(.system(size: 15, weight: .semibold))
            if model.recent.isEmpty {
                Text("Your screenshots show up here. They're saved in Pictures → Dandelion Screenshots.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.recent, id: \.self) { url in ShotThumb(url: url) }
                }
            }
        }
    }
}

/// Loads one thumbnail in the background, so a folder full of big screenshots never stalls the window.
@MainActor
final class ThumbLoader: ObservableObject {
    @Published var image: NSImage?
    private var loaded: URL?

    func load(_ url: URL) {
        guard loaded != url else { return }
        loaded = url
        image = ScreenshotModel.cachedThumbnail(url)
        guard image == nil else { return }
        Task { @MainActor in
            let img = await ScreenshotModel.loadThumbnail(url)
            if self.loaded == url { withAnimation(.easeOut(duration: 0.15)) { self.image = img } }
        }
    }
}

struct ShotThumb: View {
    @EnvironmentObject var model: ScreenshotModel
    @StateObject private var loader = ThumbLoader()
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.primary.opacity(0.06)
                if let img = loader.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .onAppear { loader.load(url) }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { model.openEditor(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Mark Up") { model.openEditor(url) }
            Button("Copy") { model.copy(url) }
            Button("Pin to Screen") { model.pin(url) }
            Button("Show in Finder") { model.reveal(url) }
            Divider()
            Button("Move to Trash") { model.trash(url) }
        }
        .help("Click to mark up. Drag it into any app.")
    }
}

// MARK: - editor

struct ShotEditorView: View {
    @ObservedObject var editor: ShotEditor

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.06))
        }
        .padding(.top, 28)   // room for the transparent title bar
        .sheet(isPresented: Binding(get: { editor.textPrompt != nil }, set: { if !$0 { editor.textPrompt = nil } })) {
            TextPromptSheet(editor: editor)
        }
        .overlay(alignment: .bottom) {
            if let t = editor.flashText {
                Label(t, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: editor.flashText)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(MarkKind.allCases) { k in
                    Button { editor.tool = k } label: {
                        Image(systemName: k.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 26)
                            .background(editor.tool == k ? Tool.screenshot.tint.opacity(0.22) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(editor.tool == k ? Tool.screenshot.tint : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(k.title)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 5) {
                ForEach(Array(MarkPalette.colors.enumerated()), id: \.offset) { i, c in
                    Button { editor.color = i } label: {
                        Circle()
                            .fill(Color(nsColor: c))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                            .padding(2)
                            .overlay(Circle().stroke(editor.color == i ? Color.primary.opacity(0.7) : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!editor.canUndo)
                .help("Undo")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.canRedo)
                .help("Redo")

            Spacer()

            Image(systemName: "hand.draw")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .onDrag { editor.dragProvider() }
                .help("Drag the marked-up screenshot into any app")
            Button { editor.pin() } label: { Label("Pin", systemImage: "pin") }
                .help("Float it above every window")
            Button { editor.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: .command)
            Menu {
                Button("Save") { editor.save() }
                Button("Save As…") { editor.saveAs() }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            } primaryAction: {
                editor.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .fixedSize()
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let px = editor.pixelSize
            let s = min(geo.size.width / max(px.width, 1), geo.size.height / max(px.height, 1))
            let size = CGSize(width: px.width * s, height: px.height * s)
            ZStack {
                Image(nsImage: editor.nsImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                Canvas { gc, _ in
                    let marks = editor.marks + (editor.draft.map { [$0] } ?? [])
                    let pixelated = editor.pixelated
                    gc.withCGContext { ctx in
                        ctx.scaleBy(x: s, y: s)
                        MarkDrawer.draw(marks, in: ctx, imageSize: px, pixelated: pixelated)
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let p = CGPoint(x: v.location.x / s, y: v.location.y / s)
                            if editor.draft == nil && editor.textPrompt == nil {
                                editor.begin(at: CGPoint(x: v.startLocation.x / s, y: v.startLocation.y / s))
                            }
                            editor.move(to: p)
                        }
                        .onEnded { _ in editor.end() }
                )
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct TextPromptSheet: View {
    @ObservedObject var editor: ShotEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add text").font(.system(size: 15, weight: .semibold))
            TextField("Type something", text: Binding(get: { editor.textEntry }, set: { editor.textEntry = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { editor.commitText() }
            HStack {
                Spacer()
                Button("Cancel") { editor.textPrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { editor.commitText() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
