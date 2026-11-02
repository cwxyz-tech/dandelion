// Dandelion - the suite: a sidebar of tools, each fixing one everyday Mac annoyance.
// MIT License. See LICENSE.

import AppKit
import QuickLook
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case diskMap, duplicates, rules, screenshot, timeTracker, recorder
    var id: String { rawValue }

    var title: String {
        switch self {
        case .diskMap: return "Disk Map"
        case .duplicates: return "Duplicates"
        case .rules: return "Folder Rules"
        case .screenshot: return "Screenshot"
        case .timeTracker: return "Time Tracker"
        case .recorder: return "Screen Recorder"
        }
    }

    var symbol: String {
        switch self {
        case .diskMap: return "chart.pie.fill"
        case .duplicates: return "square.on.square.fill"
        case .rules: return "folder.fill.badge.gearshape"
        case .screenshot: return "camera.viewfinder"
        case .timeTracker: return "clock.fill"
        case .recorder: return "record.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .diskMap: return Color(red: 0.95, green: 0.45, blue: 0.2)
        case .duplicates: return Color(red: 0.35, green: 0.5, blue: 0.98)
        case .rules: return Color(red: 0.2, green: 0.72, blue: 0.45)
        case .screenshot: return Color(red: 0.9, green: 0.3, blue: 0.55)
        case .timeTracker: return Color(red: 0.6, green: 0.4, blue: 0.95)
        case .recorder: return Color(red: 0.95, green: 0.3, blue: 0.3)
        }
    }

    var ready: Bool { true }

    /// The tools that are actually in the app (the sidebar and the Tools menu only show these).
    static var shipped: [Tool] { allCases.filter { $0.ready } }

    var blurb: String {
        switch self {
        case .diskMap: return "See what's taking up space"
        case .duplicates: return "Find and clear copies"
        case .rules: return "Keep folders tidy on their own"
        case .screenshot: return "Capture, mark up, pin"
        case .timeTracker: return "See where your day goes"
        case .recorder: return "Recordings that zoom to your clicks"
        }
    }
}

enum Brand {
    static let catchphrase = "Make a wish. Clear your Mac."
}

struct SuiteView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            ZStack {
                switch state.tool {
                case .diskMap: DiskMapView().transition(.opacity)
                case .duplicates: DuplicatesView().transition(.opacity)
                case .rules: RulesView().transition(.opacity)
                case .screenshot: ScreenshotView().transition(.opacity)
                case .timeTracker: TimeTrackerView().transition(.opacity)
                case .recorder: RecorderView().transition(.opacity)
                }
            }
            .animation(state.reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.tool)
        }
        .overlay(alignment: .bottom) {
            if let t = state.toast {
                ToastView(toast: t)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(t.id)
            }
        }
        .onAppear {
            let open = openWindow
            state.openMainWindow = { open(id: "main") }
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

struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding<Tool?>(
            get: { state.tool },
            set: { if let t = $0 { state.tool = t } })
        ) {
            // Tools still being built stay out of the sidebar until they ship.
            Section("Tools") {
                ForEach(Tool.shipped) { t in row(t).tag(t) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dandelion").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(Brand.catchphrase).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .safeAreaInset(edge: .bottom) {
            Text("Version \(state.appVersion) · Free and open source")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }

    private func row(_ t: Tool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: t.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(t.tint.opacity(t.ready ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 0) {
                Text(t.title).font(.system(size: 13, weight: .medium))
                Text(t.blurb).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !t.ready {
                Spacer(minLength: 4)
                Text("SOON")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .opacity(t.ready ? 1 : 0.75)
    }
}

/// A big, tinted header used at the top of each tool.
struct ToolHeader: View {
    let tool: Tool
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tool.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: [tool.tint, tool.tint.opacity(0.72)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: tool.tint.opacity(0.35), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
