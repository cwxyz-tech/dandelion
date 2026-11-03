// Dandelion - the suite: a sidebar of three tools, each fixing one everyday Mac annoyance.
// MIT License. See LICENSE.

import AppKit
import QuickLook
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case diskMap, duplicates, rules
    var id: String { rawValue }

    var title: String {
        switch self {
        case .diskMap: return "Disk Map"
        case .duplicates: return "Duplicates"
        case .rules: return "Folder Rules"
        }
    }

    var symbol: String {
        switch self {
        case .diskMap: return "chart.pie.fill"
        case .duplicates: return "square.on.square.fill"
        case .rules: return "folder.fill.badge.gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .diskMap: return Color(red: 0.96, green: 0.48, blue: 0.18)
        case .duplicates: return Color(red: 0.33, green: 0.48, blue: 0.98)
        case .rules: return Color(red: 0.16, green: 0.70, blue: 0.45)
        }
    }

    var blurb: String {
        switch self {
        case .diskMap: return "See what's taking up space"
        case .duplicates: return "Find and clear copies"
        case .rules: return "Folders that tidy themselves"
        }
    }

    /// Every tool in the app (kept as its own name so menus read clearly).
    static var shipped: [Tool] { allCases }
}

enum Brand {
    static let catchphrase = "Make a wish. Clear your Mac."
}

struct SuiteView: View {
    @EnvironmentObject var state: AppState

    /// A soft wash of the current tool's color behind the top of the window. Left off while the
    /// disk chart is up, so nothing competes with it.
    private var showsWash: Bool { !(state.tool == .diskMap && state.phase != .home) }

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            ZStack {
                switch state.tool {
                case .diskMap: DiskMapView().transition(.opacity)
                case .duplicates: DuplicatesView().navigationTitle(Tool.duplicates.title).transition(.opacity)
                case .rules: RulesView().navigationTitle(Tool.rules.title).transition(.opacity)
                }
            }
            .background(alignment: .top) {
                if showsWash {
                    LinearGradient(colors: [state.tool.tint.opacity(0.10), state.tool.tint.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 280)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(state.reduceMotion ? nil : .easeInOut(duration: 0.25), value: state.tool)
            .animation(state.reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsWash)
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
                ForEach(Tool.shipped) { t in row(t).tag(t) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dandelion").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Make a wish.\nClear your Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(0)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Nothing ever leaves your Mac")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("Version \(state.appVersion) · Free and open source")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private func row(_ t: Tool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: t.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(LinearGradient(colors: [t.tint, t.tint.opacity(0.78)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 7.5))
                .shadow(color: t.tint.opacity(0.3), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.system(size: 13, weight: .medium))
                Text(t.blurb).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A big, tinted header used at the top of each tool.
struct ToolHeader: View {
    let tool: Tool
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: tool.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(LinearGradient(colors: [tool.tint, tool.tint.opacity(0.72)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .shadow(color: tool.tint.opacity(0.35), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
