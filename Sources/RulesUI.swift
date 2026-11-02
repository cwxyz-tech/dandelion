// Dandelion - the Folder Rules screens, and the watcher that runs rules automatically.
// MIT License. See LICENSE.
//
// View state is stored with State(...) directly instead of the @State attribute: in the macOS 26 SDK
// @State is a macro, and the Command Line Tools don't ship the plugin that expands it.

import AppKit
import SwiftUI

@MainActor
final class RulesModel: ObservableObject {
    @Published var rules: [FolderRule] = []
    @Published var autoRun: Bool {
        didSet {
            UserDefaults.standard.set(autoRun, forKey: "rulesAutoRun")
            refreshWatching()
        }
    }
    /// Everything rules have done this session, newest first.
    @Published var log: [RuleLogEntry] = []
    /// The most recent run, for Undo.
    @Published var lastRun: [RuleLogEntry] = []
    @Published var editing: FolderRule?
    @Published var previewing: FolderRule?
    @Published var previewMoves: [PlannedMove] = []
    @Published var running = false

    weak var app: AppState?
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private var sweep: Timer?
    /// Files put back with Undo this session (path → file ID). Automatic runs leave them alone,
    /// otherwise the watcher would notice them coming back and move them straight away again.
    private var undone: [String: UInt64] = [:]

    init() {
        autoRun = UserDefaults.standard.bool(forKey: "rulesAutoRun")
        rules = RulesEngine.load()
    }

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func start() { refreshWatching() }

    // MARK: editing

    func save() {
        do { try RulesEngine.save(rules) } catch {
            app?.alertMessage = "Your rules couldn't be saved: \(error.localizedDescription)"
        }
        refreshWatching()
    }

    func newRule(from template: FolderRule?) {
        editing = template ?? FolderRule(name: "New Rule", folder: NSHomeDirectory() + "/Downloads",
                                         conditions: [RuleCondition(kind: .kindIs, fileKind: .installer)],
                                         action: RuleAction(kind: .moveToTrash))
        if template != nil { editing?.id = UUID() }
    }

    func commit(_ rule: FolderRule) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
            if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
        }
        editing = nil
        save()
    }

    func delete(_ rule: FolderRule) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) { rules.removeAll { $0.id == rule.id } }
        save()
    }

    func setEnabled(_ rule: FolderRule, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i].enabled = on
        save()
    }

    // MARK: running

    func preview(_ rule: FolderRule) {
        if let problem = RulesEngine.problem(with: rule) {
            app?.show(Toast(text: problem, symbol: "exclamationmark.triangle.fill", tint: .orange))
            return
        }
        var r = rule
        r.enabled = true
        previewMoves = RulesEngine.plan(r)
        previewing = rule
    }

    func runPreviewed() {
        guard let rule = previewing else { return }
        let moves = previewMoves
        previewing = nil
        execute([(rule, moves)], automatic: false)
    }

    /// Runs every enabled rule (optionally only those watching one folder).
    func runAll(folder: String? = nil, automatic: Bool) {
        let chosen = rules.filter { $0.enabled && RulesEngine.problem(with: $0) == nil && (folder == nil || standard($0.folder) == folder) }
        let work = chosen.map { r in (r, RulesEngine.plan(r).filter { !automatic || undone[$0.source] != $0.fileID }) }
            .filter { !$0.1.isEmpty }
        if work.isEmpty {
            if !automatic { app?.show(Toast(text: "Nothing to do. Your folders are already tidy.", symbol: "checkmark.circle.fill", tint: .green)) }
            return
        }
        execute(work, automatic: automatic)
    }

    private func execute(_ work: [(FolderRule, [PlannedMove])], automatic: Bool) {
        guard !running else { return }
        running = true
        Task.detached(priority: .utility) {
            var done: [RuleLogEntry] = []
            var problems: [String] = []
            for (_, moves) in work {
                let r = RulesEngine.run(moves)
                done += r.done
                problems += r.problems
            }
            await self.finish(done: done, problems: problems, automatic: automatic)
        }
    }

    private func finish(done: [RuleLogEntry], problems: [String], automatic: Bool) {
        running = false
        if !done.isEmpty {
            lastRun = done
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
                log.insert(contentsOf: done.reversed(), at: 0)
                if log.count > 300 { log.removeLast(log.count - 300) }
            }
            let n = done.count
            app?.show(Toast(text: "\(automatic ? "Folder Rules tidied" : "Moved") \(n == 1 ? "1 file" : "\(n) files"). Undo is in Folder Rules.",
                            symbol: "wand.and.stars", tint: Tool.rules.tint))
        }
        if !problems.isEmpty && !automatic {
            app?.alertMessage = "Some files were left alone:\n\n" + problems.joined(separator: "\n")
        }
    }

    func undoLast() {
        let entries = lastRun
        guard !entries.isEmpty else { return }
        lastRun = []
        Task.detached(priority: .userInitiated) {
            var back: [(String, UInt64)] = []
            let problems = RulesEngine.undo(entries) { path, id in back.append((path, id)) }
            await MainActor.run {
                for (path, id) in back { self.undone[path] = id }
                let undone = Set(entries.map { $0.id })
                withAnimation(self.reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
                    self.log.removeAll { undone.contains($0.id) }
                }
                self.app?.show(Toast(text: "Put \(entries.count == 1 ? "1 file" : "\(entries.count) files") back.", symbol: "arrow.uturn.backward.circle.fill", tint: .blue))
                if !problems.isEmpty { self.app?.alertMessage = "Some files couldn't be put back:\n\n" + problems.joined(separator: "\n") }
            }
        }
    }

    // MARK: watching folders (while Dandelion is open)

    private func standard(_ p: String) -> String { (p as NSString).standardizingPath }

    /// Watches each rule's folder; a change waits a little (for downloads to finish), then runs that folder's rules.
    /// A sweep every 15 minutes catches the "older than" conditions as time passes.
    func refreshWatching() {
        let wanted: Set<String> = autoRun ? Set(rules.filter { $0.enabled }.map { standard($0.folder) }) : []
        for (folder, src) in watchers where !wanted.contains(folder) {
            src.cancel()
            watchers[folder] = nil
        }
        for folder in wanted where watchers[folder] == nil { watch(folder) }
        sweep?.invalidate()
        sweep = nil
        if autoRun {
            sweep = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
                Task { @MainActor in self.rearm(); self.runAll(automatic: true) }
            }
            runAll(automatic: true)
        }
    }

    /// Re-opens watchers for folders that came back (without kicking off another full run).
    private func rearm() {
        guard autoRun else { return }
        let wanted = Set(rules.filter { $0.enabled }.map { standard($0.folder) })
        for folder in wanted where watchers[folder] == nil { watch(folder) }
    }

    private func watch(_ folder: String) {
        let fd = open(folder, O_EVTONLY | O_CLOEXEC)
        if fd < 0 { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        // (the model lives as long as the app, so holding on to it here is fine)
        src.setEventHandler { [weak src] in
            let gone = src.map { !$0.data.intersection([.delete, .rename]).isEmpty } ?? false
            let me = src.map { ObjectIdentifier($0 as AnyObject) }
            Task { @MainActor in
                if gone {
                    // the folder itself was moved or deleted: stop watching the old one, look again shortly
                    guard let w = self.watchers[folder], ObjectIdentifier(w as AnyObject) == me else { return }
                    w.cancel()
                    self.watchers[folder] = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Task { @MainActor in self.rearm() } }
                } else {
                    self.folderChanged(folder)
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers[folder] = src
    }

    private func folderChanged(_ folder: String) {
        pending[folder]?.cancel()
        let item = DispatchWorkItem {
            Task { @MainActor in self.runAll(folder: folder, automatic: true) }
        }
        pending[folder] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
    }

    // MARK: describing

    func summary(_ r: FolderRule) -> String {
        let folder = FileManager.default.displayName(atPath: r.folder)
        let conds = r.conditions.map { c -> String in
            switch c.kind {
            case .kindIs: return "it's \(article(c.fileKind.rawValue.lowercased()))"
            case .nameContains: return "the name contains \u{201C}\(c.text)\u{201D}"
            case .extensionIs: return "it's a .\(c.text.replacingOccurrences(of: ", ", with: "/.").replacingOccurrences(of: ",", with: "/.")) file"
            case .addedMoreThanDaysAgo: return "it was added over \(Int(c.number)) day\(Int(c.number) == 1 ? "" : "s") ago"
            case .modifiedMoreThanDaysAgo: return "it was changed over \(Int(c.number)) day\(Int(c.number) == 1 ? "" : "s") ago"
            case .largerThanMB: return "it's over \(Fmt.bytes(Int64(c.number * 1_000_000)))"
            case .smallerThanMB: return "it's under \(Fmt.bytes(Int64(c.number * 1_000_000)))"
            }
        }
        let when = conds.isEmpty ? "every file" : "a file where " + conds.joined(separator: r.matchAll ? " and " : " or ")
        let action: String
        switch r.action.kind {
        case .moveTo: action = "move it to \(FileManager.default.displayName(atPath: r.action.destination.isEmpty ? "?" : r.action.destination))"
        case .sortByType: action = "sort it into a folder for its type"
        case .sortByMonth: action = "sort it into a folder for its month"
        case .moveToTrash: action = "move it to the Trash"
        }
        return "In \(folder), for \(when): \(action)."
    }

    private func article(_ w: String) -> String {
        ["a", "e", "i", "o", "u"].contains(w.prefix(1)) ? "an \(w)" : "a \(w)"
    }
}

// MARK: - Views

struct RulesView: View {
    @EnvironmentObject var model: RulesModel

    private static let times: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ToolHeader(tool: .rules, subtitle: "Keep folders tidy on their own. Set a rule once and forget about it.")
                autoCard
                HStack {
                    Text("Your rules").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button { model.runAll(automatic: false) } label: { Label("Run All Now", systemImage: "play.fill") }
                        .disabled(model.rules.filter { $0.enabled }.isEmpty || model.running)
                    Menu {
                        ForEach(RulesEngine.templates(), id: \.name) { t in
                            Button(t.name) { model.newRule(from: t) }
                        }
                        Divider()
                        Button("Blank Rule") { model.newRule(from: nil) }
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                    .fixedSize()
                }
                if model.rules.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(model.rules.enumerated()), id: \.element.id) { i, r in
                            RuleCard(rule: r, index: i)
                                .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                        }
                    }
                }
                activity
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: Binding(get: { model.editing }, set: { model.editing = $0 })) { rule in
            RuleEditor(rule: rule, model: model)
        }
        .sheet(item: Binding(get: { model.previewing }, set: { model.previewing = $0 })) { rule in
            RulePreview(rule: rule, moves: model.previewMoves, model: model)
        }
    }

    private var autoCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.autoRun ? "bolt.circle.fill" : "bolt.slash.circle")
                .font(.system(size: 24))
                .foregroundStyle(model.autoRun ? Tool.rules.tint : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text("Run rules automatically").font(.system(size: 13, weight: .semibold))
                Text("While Dandelion is open (it can sit in the background), new files are handled a few seconds after they land, and everything gets a sweep every 15 minutes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.autoRun }, set: { v in withAnimation { model.autoRun = v } }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start with one of these:").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(RulesEngine.templates(), id: \.name) { t in
                Button { model.newRule(from: t) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars").foregroundStyle(Tool.rules.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.system(size: 13, weight: .semibold))
                            Text(model.summary(t)).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill").foregroundStyle(Tool.rules.tint)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent activity").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !model.lastRun.isEmpty {
                    Button { model.undoLast() } label: {
                        Label("Undo Last Run (\(model.lastRun.count))", systemImage: "arrow.uturn.backward")
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            if model.log.isEmpty {
                Text("Nothing yet. When a rule moves something, it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.log.prefix(60)) { e in
                        HStack(spacing: 8) {
                            Image(systemName: e.toTrash ? "trash" : "arrow.right.circle")
                                .foregroundStyle(e.toTrash ? Color.red : Tool.rules.tint)
                            Text(DisplayName.clean((e.from as NSString).lastPathComponent)).font(.system(size: 12)).lineLimit(1)
                            Text(e.toTrash ? "→ Trash" : "→ \(DisplayName.clean(FileManager.default.displayName(atPath: (e.to as NSString).deletingLastPathComponent)))")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(e.ruleName).font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(Self.times.string(from: e.date)).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .animation(model.reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: model.lastRun.count)
    }
}

struct RuleCard: View {
    @EnvironmentObject var model: RulesModel
    let rule: FolderRule
    let index: Int
    private var shownStore = State(initialValue: false)

    init(rule: FolderRule, index: Int) {
        self.rule = rule
        self.index = index
    }

    var body: some View {
        let shown = shownStore.wrappedValue
        let problem = RulesEngine.problem(with: rule)
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { model.setEnabled(rule, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name).font(.system(size: 14, weight: .semibold))
                Text(model.summary(rule)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let p = problem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Button { model.preview(rule) } label: { Label("Preview", systemImage: "eye") }
                Button { model.editing = rule } label: { Image(systemName: "pencil") }.help("Edit")
                Button(role: .destructive) { model.delete(rule) } label: { Image(systemName: "trash") }.help("Delete this rule")
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.primary.opacity(rule.enabled ? 0.045 : 0.02), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(rule.enabled ? Tool.rules.tint.opacity(0.25) : Color.primary.opacity(0.06)))
        .opacity(shown ? (rule.enabled ? 1 : 0.65) : 0)
        .offset(y: shown ? 0 : 10)
        .onAppear {
            if model.reduceMotion { shownStore.wrappedValue = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(Double(index) * 0.05)) { shownStore.wrappedValue = true }
        }
    }
}

struct RulePreview: View {
    let rule: FolderRule
    let moves: [PlannedMove]
    let model: RulesModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rule.name).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(moves.isEmpty ? "Right now this rule wouldn't touch anything." : "Right now this rule would handle \(moves.count == 1 ? "1 file" : "\(moves.count) files"):")
                .foregroundStyle(.secondary)
            if !moves.isEmpty {
                List(moves) { m in
                    HStack(spacing: 8) {
                        Image(nsImage: Icons.shared.icon(forPath: m.source)).resizable().frame(width: 18, height: 18)
                        Text(DisplayName.clean((m.source as NSString).lastPathComponent)).lineLimit(1)
                        Spacer()
                        Text(m.destination.map { "→ " + DisplayName.clean(((($0 as NSString).deletingLastPathComponent) as NSString).abbreviatingWithTildeInPath) } ?? "→ Trash")
                            .foregroundStyle(m.destination == nil ? Color.red : Color.secondary)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12))
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if !moves.isEmpty {
                    Button("Run Now") { model.runPreviewed() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

struct RuleEditor: View {
    let model: RulesModel
    @Environment(\.dismiss) private var dismiss
    private var draftStore: State<FolderRule>

    init(rule: FolderRule, model: RulesModel) {
        self.model = model
        draftStore = State(initialValue: rule)
    }

    var body: some View {
        let draft = draftStore.projectedValue
        let value = draftStore.wrappedValue
        let problem = RulesEngine.problem(with: value)
        let count = problem == nil ? RulesEngine.plan({ var r = value; r.enabled = true; return r }()).count : 0
        VStack(alignment: .leading, spacing: 16) {
            TextField("Rule name", text: draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Watch").frame(width: 60, alignment: .leading)
                        Image(nsImage: Icons.shared.icon(forPath: value.folder)).resizable().frame(width: 18, height: 18)
                        Text((value.folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { if let p = choose("Choose the folder this rule watches") { draft.wrappedValue.folder = p } }
                    }
                    HStack {
                        Text("If").frame(width: 60, alignment: .leading)
                        Picker("", selection: draft.matchAll) {
                            Text("all").tag(true)
                            Text("any").tag(false)
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        Text("of these are true:")
                        Spacer()
                    }
                    ForEach(draft.conditions) { c in
                        HStack(spacing: 8) {
                            Picker("", selection: c.kind) {
                                ForEach(RuleCondition.Kind.allCases) { k in Text(k.rawValue).tag(k) }
                            }
                            .labelsHidden()
                            .frame(width: 230)
                            switch c.wrappedValue.kind {
                            case .kindIs:
                                Picker("", selection: c.fileKind) {
                                    ForEach(FileKind.allCases) { k in Text(k.rawValue).tag(k) }
                                }
                                .labelsHidden()
                                .frame(width: 150)
                            case .nameContains:
                                TextField("text", text: c.text).frame(width: 180)
                            case .extensionIs:
                                TextField("e.g. zip, dmg", text: c.text).frame(width: 180)
                            default:
                                TextField("", value: c.number, format: .number).frame(width: 80)
                            }
                            Spacer()
                            Button { draft.wrappedValue.conditions.removeAll { $0.id == c.wrappedValue.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 60)
                    }
                    Button { draft.wrappedValue.conditions.append(RuleCondition(kind: .addedMoreThanDaysAgo)) } label: {
                        Label("Add Condition", systemImage: "plus")
                    }
                    .padding(.leading, 60)
                    HStack {
                        Text("Then").frame(width: 60, alignment: .leading)
                        Picker("", selection: draft.action.kind) {
                            ForEach(RuleAction.Kind.allCases) { k in Text(k.rawValue).tag(k) }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        Spacer()
                    }
                    if value.action.kind != .moveToTrash {
                        HStack {
                            Text(value.action.kind == .moveTo ? "To" : "Inside").frame(width: 60, alignment: .leading)
                            Text(value.action.destination.isEmpty
                                 ? (value.action.kind == .moveTo ? "Choose a folder" : "The watched folder")
                                 : (value.action.destination as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(value.action.destination.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { if let p = choose("Choose where files go") { draft.wrappedValue.action.destination = p } }
                            if !value.action.destination.isEmpty && value.action.kind != .moveTo {
                                Button("Reset") { draft.wrappedValue.action.destination = "" }
                            }
                        }
                    }
                }
                .padding(6)
            }
            Group {
                if let p = problem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Label(count == 0 ? "Right now this wouldn't touch anything." : "Right now this would handle \(count == 1 ? "1 file" : "\(count) files").",
                          systemImage: "eye").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .animation(.snappy(duration: 0.2), value: count)
            Text("Rules only look at files sitting directly in the folder, skip anything still downloading, never overwrite a file, and can always be undone.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Rule") { model.commit(draftStore.wrappedValue) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil || value.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private func choose(_ message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
