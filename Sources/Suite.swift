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

    var ready: Bool { [.diskMap, .duplicates, .rules].contains(self) }

    var blurb: String {
        switch self {
        case .diskMap: return "See what's taking up space"
        case .duplicates: return "Find and clear copies"
        case .rules: return "Keep folders tidy on their own"
        case .screenshot: return "Capture, mark up, pin"
        case .timeTracker: return "See where your time goes"
        case .recorder: return "Recordings that zoom to your clicks"
        }
    }
}

enum Brand {
    static let catchphrase = "Blow away the clutter."
}

struct SuiteView: View {
    @EnvironmentObject var state: AppState

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
                case .screenshot, .timeTracker, .recorder: ComingSoonView(tool: state.tool).transition(.opacity)
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
            Section("Tools") {
                ForEach(Tool.allCases.filter { $0.ready }) { t in row(t).tag(t) }
            }
            Section("Coming soon") {
                ForEach(Tool.allCases.filter { !$0.ready }) { t in row(t).tag(t) }
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

/// The tools still on the way, said plainly: what they'll do, and that they aren't here yet.
struct ComingSoonView: View {
    @EnvironmentObject var state: AppState
    let tool: Tool
    private var shownStore = State(initialValue: false)

    init(tool: Tool) { self.tool = tool }

    private var plan: (headline: String, like: String, points: [String]) {
        switch tool {
        case .screenshot:
            return ("Capture any part of the screen, mark it up, and keep it handy.", "Like CleanShot X, for free.",
                    ["Capture an area, a window or the whole screen with a shortcut",
                     "Draw arrows, boxes and text, and blur anything private",
                     "Pin a screenshot so it floats above everything",
                     "Copy, save or drag it straight into another app"])
        case .timeTracker:
            return ("See which apps and sites your day actually goes to.", "Like Timing, without the subscription.",
                    ["Logs the app you're using in the background, automatically",
                     "Daily and weekly charts by app and category",
                     "Everything stays on your Mac, never uploaded anywhere",
                     "Pause any time, and delete any day's history"])
        case .recorder:
            return ("Screen recordings that zoom in smoothly wherever you click.", "Like Screen Studio, minus the $89.",
                    ["Record the screen, a window or an area, with your mic",
                     "Automatic smooth zooms that follow your clicks",
                     "A polished cursor, padding and background",
                     "Export for YouTube, social or anywhere else"])
        default:
            return ("", "", [])
        }
    }

    var body: some View {
        let shown = shownStore.wrappedValue
        let p = plan
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: tool.symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(LinearGradient(colors: [tool.tint, tool.tint.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: tool.tint.opacity(0.4), radius: 16, y: 8)
                .scaleEffect(shown ? 1 : 0.7)
                .rotationEffect(.degrees(shown ? 0 : -12))
            HStack(spacing: 8) {
                Text(tool.title).font(.system(size: 28, weight: .bold, design: .rounded))
                Text("COMING SOON")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(tool.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(tool.tint)
            }
            Text(p.headline).font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(p.points.enumerated()), id: \.offset) { i, point in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(tool.tint)
                        Text(point).font(.system(size: 13))
                    }
                    .opacity(shown ? 1 : 0)
                    .offset(x: shown ? 0 : 16)
                    .animation(state.reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8).delay(0.1 + Double(i) * 0.06), value: shown)
                }
            }
            .padding(20)
            .frame(maxWidth: 460, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            Text("\(p.like) It isn't built yet; it's planned for a future update.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if state.reduceMotion { shownStore.wrappedValue = true; return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { shownStore.wrappedValue = true }
        }
        .onChange(of: tool) {
            shownStore.wrappedValue = false
            withAnimation(state.reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.7)) { shownStore.wrappedValue = true }
        }
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
