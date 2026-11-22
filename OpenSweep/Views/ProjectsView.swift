import SwiftUI
import AgentEngine

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @FocusState private var searching: Bool
    /// Arrow keys move through whichever list has focus (gap G4).
    @FocusState private var pane: Pane?
    @AppStorage("projectsShowAll") private var showAll = false
    @AppStorage("projectsSort") private var sort = Sort.size

    enum Sort: String, CaseIterable { case size, name }
    enum Pane { case projects, folders }

    /// ↑/↓ in the project list: the next or previous project.
    private func step(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let roots = rows.map(\.root)
        guard !roots.isEmpty else { return .ignored }
        let now = roots.firstIndex(of: model.selectedProject ?? "") ?? (by > 0 ? -1 : roots.count)
        let next = roots[min(max(now + by, 0), roots.count - 1)]
        model.selectedProject = next
        proxy.scrollTo(next)
        return .handled
    }

    private var rows: [AgentEngine.Project] {
        (showAll ? model.projects : model.cleanable)
            .filter { search.isEmpty || $0.root.localizedCaseInsensitiveContains(search) }
            .sorted {
                switch sort {
                case .size: model.total($0) > model.total($1)
                case .name: URL(fileURLWithPath: $0.root).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: $1.root).lastPathComponent) == .orderedAscending
                }
            }
    }

    private var subtitle: String {
        let shown = rows.count
        return showAll ? "\(model.projects.count) found" : "\(shown) of \(model.projects.count) have something to clean"
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Projects", subtitle: subtitle)
                HStack(spacing: 8) {
                    Picker("Show", selection: $showAll) {
                        Text("To clean").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityIdentifier("projects.filter")
                    Spacer()
                    Picker("Sort", selection: $sort) {
                        Text("Biggest first").tag(Sort.size)
                        Text("Name").tag(Sort.name)
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Sort projects")
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Brand.muted).accessibilityHidden(true)
                    TextField("Search", text: $search).textFieldStyle(.plain)
                        .focused($searching)
                        .accessibilityLabel("Search projects")
                    Button("Find") { searching = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .hidden().frame(width: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .glassCard(radius: 9)
                if model.projects.isEmpty {
                    Spacer()
                    Text(model.scanning ? "Scanning…" : "Run a scan from Overview to find projects.")
                        .foregroundStyle(Brand.muted).frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                    ScrollView {
                        let biggest = rows.map(model.total).max() ?? 1
                        LazyVStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.root) { i, p in
                                Button { model.selectedProject = p.root; pane = .projects } label: {
                                    CompactProjectRow(project: p, total: model.total(p), share: Double(model.total(p)) / Double(max(biggest, 1)))
                                }
                                .buttonStyle(RowButtonStyle(selected: model.selectedProject == p.root))
                                .accessibilityAddTraits(model.selectedProject == p.root ? .isSelected : [])
                                .accessibilityIdentifier("project.\(URL(fileURLWithPath: p.root).lastPathComponent)")
                                .entrance(i, from: .leading)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Projects")
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($pane, equals: .projects)
                    .onKeyPress(.downArrow) { step(1, proxy) }
                    .onKeyPress(.upArrow) { step(-1, proxy) }
                    .onKeyPress(.rightArrow) {
                        guard model.project(model.selectedProject)?.items.isEmpty == false else { return .ignored }
                        pane = .folders
                        return .handled
                    }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 24)
            .frame(width: 360)
            .background(Brand.canvas)

            Divider().overlay(Brand.hairline)

            if let p = model.project(model.selectedProject) {
                // Keyed by path, not value: a refresh after a clean must not tear down
                // the open Review sheet (and its Undo).
                ProjectDetail(project: p, pane: $pane).id(p.root).entrance(0, from: .trailing)
            } else {
                VStack(spacing: 8) {
                    Peep(crew: 2, size: 96)
                    Text("Choose a project to see its folders").foregroundStyle(Brand.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if !searching { pane = .projects } }
    }
}

/// One project's folders, each ticked by hand. Safe folders start ticked in
/// projects not in use; Caution folders never do (F14).
struct ProjectDetail: View {
    @Environment(AppModel.self) private var model
    let project: AgentEngine.Project
    var pane: FocusState<ProjectsView.Pane?>.Binding
    @State private var picked: Set<String> = []
    /// The folder ↑/↓ and Space act on while the folder list has focus.
    @State private var cursor = 0
    @State private var allowActive = false
    @State private var review: CleanOutput?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    EcosystemBadge(ecosystem: project.ecosystems.first ?? Ecosystem.of(rule: ""), size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: project.root).lastPathComponent)
                            .font(.system(size: 26, weight: .bold)).tracking(-0.4).foregroundStyle(Brand.text)
                        Text(tildePath(project.root)).font(.callout.monospaced()).foregroundStyle(Brand.muted)
                            .lineLimit(1).truncationMode(.middle).help(project.root)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if project.pinned {
                            Button("Unpin") { Task { await model.setPinned(project.root, false) } }
                        } else {
                            Menu("Pin") {
                                Button("Pin for good") { Task { await model.setPinned(project.root, true) } }
                                Button("Pin for 30 days") { Task { await model.setPinned(project.root, true, days: 30) } }
                                Button("Pin this repository wherever it is cloned") {
                                    Task { await model.setPinned(project.root, true, remote: true) }
                                }
                                .disabled(!FileManager.default.fileExists(atPath: project.root + "/.git/config"))
                            } primaryAction: {
                                Task { await model.setPinned(project.root, true) }
                            }
                            .menuStyle(.button).fixedSize()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(project.pinned ? "Allow cleaning this project again" : "Never clean this project")
                    .accessibilityIdentifier("pin")
                }

                HStack(spacing: 8) {
                    if project.pinned {
                        StatusChip(text: "Pinned", systemImage: "pin.fill", tint: Brand.slate)
                    } else {
                        StatusChip(text: project.verdict.label, systemImage: project.verdict.symbol, tint: project.verdict.tint)
                    }
                    Text(project.reason).foregroundStyle(Brand.muted)
                    Spacer()
                    if project.ecosystems.count > 1 {
                        Text(project.ecosystems.map(\.name).joined(separator: ", ")).font(.callout).foregroundStyle(Brand.muted)
                    }
                }

                if project.verdict == .active && !project.pinned {
                    Toggle("Clean anyway: this project is in use", isOn: $allowActive)
                        .accessibilityIdentifier("allowActive")
                }

                if project.items.isEmpty {
                    Text("Nothing to clean here.").foregroundStyle(Brand.muted)
                } else {
                    let biggest = project.items.compactMap(\.bytes).max() ?? 1
                    let keys = pane.wrappedValue == .folders
                    VStack(spacing: 0) {
                        ForEach(Array(project.items.enumerated()), id: \.element.path) { i, item in
                            itemRow(item, share: Double(item.bytes ?? 0) / Double(max(biggest, 1)))
                                .background(keys && i == cursor ? Brand.teal.opacity(0.10) : .clear)
                                .overlay(alignment: .leading) {
                                    if keys && i == cursor { Rectangle().fill(Brand.teal).frame(width: 3) }
                                }
                                .entrance(i + 1)
                            if i < project.items.count - 1 { Divider().overlay(Brand.hairline).padding(.leading, 76) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .glassCard()
                    .focusable()
                    .focusEffectDisabled()
                    .focused(pane, equals: .folders)
                    .onKeyPress(.downArrow) { cursor = min(cursor + 1, project.items.count - 1); return .handled }
                    .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
                    .onKeyPress(.leftArrow) { pane.wrappedValue = .projects; return .handled }
                    .onKeyPress(.space) {
                        guard project.items.indices.contains(cursor), !project.pinned,
                              Selection.selectable(project.items[cursor]) else { return .ignored }
                        let path = Selection.path(project.items[cursor], in: project)
                        if picked.contains(path) { picked.remove(path) } else { picked.insert(path) }
                        return .handled
                    }
                    .accessibilityHint("Arrow keys move between folders; Space ticks one")
                }
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 90)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bytes(Selection.bytes(of: picked, in: project))).font(.figure(20)).foregroundStyle(Brand.text)
                    Text(picked.count == 1 ? "1 folder selected" : "\(picked.count) folders selected").font(.caption).foregroundStyle(Brand.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("selection.summary")
                Spacer()
                Button("Review…") {
                    Task {
                        busy = true
                        review = await model.review(picked, in: project)
                        busy = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || busy || (project.verdict == .active && !allowActive))
                .accessibilityIdentifier("review")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .floatingBar(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 24).padding(.bottom, 18)
        }
        .onAppear { picked = Selection.defaults(for: project) }
        .onChange(of: project) { _, fresh in
            // Drop ticks on folders that are gone or can no longer be cleaned (pinned).
            let still = Set(fresh.items.filter(Selection.selectable).map { Selection.path($0, in: fresh) })
            picked.formIntersection(still)
        }
        .sheet(item: $review) { out in
            ReviewSheet(project: project, picked: picked, dryRun: out)
        }
    }

    /// "up to" when the folder shares space with files elsewhere (F8).
    private func size(_ item: Item) -> String? {
        item.bytes.map { (item.shared == true ? "up to " : "") + bytes($0) }
    }

    private func itemRow(_ item: Item, share: Double) -> some View {
        let path = Selection.path(item, in: project)
        let on = Binding(
            get: { picked.contains(path) },
            set: { if $0 { picked.insert(path) } else { picked.remove(path) } })
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: on).labelsHidden().toggleStyle(.checkbox)
                .disabled(!Selection.selectable(item) || project.pinned)
                .accessibilityIdentifier("item.\(item.path)")
                .accessibilityLabel("\(item.path), \(item.kind.label), \(size(item) ?? "size unknown")")
                .accessibilityHint(item.refused.map { "Kept: \($0)" } ?? item.kind.explanation)
            .padding(.top, 5)
            EcosystemBadge(ecosystem: Ecosystem.of(rule: item.rule), size: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.path).font(.body.monospaced().weight(.semibold)).foregroundStyle(Brand.text)
                    StatusChip(text: item.kind.label, systemImage: item.kind == .safe ? "checkmark.shield.fill" : "exclamationmark.triangle.fill", tint: item.kind.tint)
                }
                Text(item.refused.map { "Kept: \($0)" } ?? item.kind.explanation
                     + (item.shared == true ? " Some files are shared with a package store or other copies, so cleaning may free less." : ""))
                    .font(.callout).foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(size(item) ?? "—").font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Brand.text)
                ShareBar(share: share, tint: Ecosystem.of(rule: item.rule).color).frame(width: 72)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .opacity(item.refused == nil ? 1 : 0.6)
    }
}

extension CleanOutput: @retroactive Identifiable {
    public var id: String { run?.runId ?? "dry-\(folders)-\(bytes)-\(projects.first?.items.count ?? 0)" }
}

/// The dry run's answer, then the real clean of exactly the same folders.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let plan: [CleanPick]
    let dryRun: CleanOutput

    init(plan: [CleanPick], dryRun: CleanOutput) {
        self.plan = plan
        self.dryRun = dryRun
    }

    init(project: AgentEngine.Project, picked: Set<String>, dryRun: CleanOutput) {
        self.init(plan: [CleanPick(project: project, picked: picked)], dryRun: dryRun)
    }
    @State private var done: CleanOutput?
    @State private var busy = false

    private var shown: CleanOutput { done ?? dryRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(done == nil ? "Move to quarantine?" : "Moved to quarantine")
                .font(.title2.weight(.semibold))
            Text(done == nil ? before : after)
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(shown.projects, id: \.root) { p in
                    if shown.projects.count > 1 {
                        Text(URL(fileURLWithPath: p.root).lastPathComponent).font(.headline).foregroundStyle(Brand.text)
                    }
                // Keyed by full path: keyed by name alone, List reused one
                // project's row (and size) for the same folder in another.
                ForEach(p.items.map { (key: p.root + "/" + $0.path, item: $0) }, id: \.key) { row in
                    let item = row.item
                    HStack {
                        Image(systemName: item.action == .move ? "arrow.right.circle.fill" : "minus.circle")
                            .foregroundStyle(item.action == .move ? Brand.teal : Brand.slate)
                            .accessibilityLabel(item.action == .move ? "Will move" : "Kept")
                        Text(item.path).font(.body.monospaced())
                        Text(item.kind.label).font(.caption).foregroundStyle(item.kind.tint)
                        Spacer()
                        Text(item.bytes.map(bytes) ?? (item.reason ?? "kept")).foregroundStyle(Brand.muted)
                    }
                }
                }
                if let entries = done?.run?.entries.filter({ $0.state != .moved }), !entries.isEmpty {
                    ForEach(entries, id: \.stored) { e in
                        Text("\(URL(fileURLWithPath: e.original).lastPathComponent): \(e.state.rawValue), \(e.note ?? "")")
                            .foregroundStyle(Brand.amber)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                if let run = done?.run {
                    Button("Undo") {
                        Task { await model.restore(run); dismiss() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("undo")
                }
                Spacer()
                if done == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Move \(shown.folders) folders") { confirm() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(shown.folders == 0 || busy)
                    .accessibilityIdentifier("confirmClean")
                    .demoPress("confirmClean") { confirm() }
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("done")
                        .demoPress("done") { dismiss() }
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: plan.count > 1 ? 560 : 460)
    }

    private func confirm() {
        Task {
            busy = true
            done = await model.clean(plan, execute: true)
            busy = false
        }
    }

    private var projectsText: String {
        plan.count > 1 ? " in \(plan.count) projects" : ""
    }

    private var before: String {
        let back = model.freesOn.map { "The space comes back on its own on \($0.formatted(date: .abbreviated, time: .omitted)), or purge sooner in History." }
            ?? "The space comes back when you purge them in History."
        return "\(shown.folders) folders\(projectsText), \(bytes(shown.bytes)). They stay restorable until then. \(back)"
    }

    private var after: String {
        let moved = done?.run?.entries.filter { $0.state == .moved }.count ?? 0
        let back = model.freesOn.map { " Space comes back on \($0.formatted(date: .abbreviated, time: .omitted))." } ?? " Purge in History to free the space."
        return "\(moved) folders moved. Undo from here or from History.\(back)"
    }
}

/// A list row in the Projects column: narrower than ProjectRow.
struct CompactProjectRow: View {
    let project: AgentEngine.Project
    let total: UInt64
    var share: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            EcosystemStack(ecosystems: project.ecosystems.isEmpty ? [Ecosystem.of(rule: "")] : project.ecosystems, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: project.root).lastPathComponent).font(.body.weight(.semibold)).foregroundStyle(Brand.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: project.pinned ? "pin.fill" : project.verdict.symbol).font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                    Text(project.pinned ? "Pinned" : project.verdict.label)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(project.pinned ? Brand.slate : project.verdict.tint)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(total == 0 ? "—" : bytes(total)).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Brand.text)
                ShareBar(share: share, tint: project.ecosystems.first?.color ?? Brand.teal).frame(width: 56)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// "Review all ready": one dry run over every project's default ticks
/// (optionally one language's), then the usual Review sheet with one Undo.
struct ReviewAllButton: View {
    @Environment(AppModel.self) private var model
    var rule: String? = nil
    var title = "Review all ready"
    @State private var review: CleanOutput?
    @State private var plan: [CleanPick] = []
    @State private var busy = false

    var body: some View {
        let ready = model.readyPlan(rule: rule)
        Button(title) { start(ready) }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(ready.isEmpty || busy || model.scanning)
        .help(ready.isEmpty ? "Nothing is ready: active, pinned and reinstall folders are left for you to pick." : "Safe folders in idle and dormant projects")
        .accessibilityIdentifier(rule.map { "reviewAll.\($0)" } ?? "reviewAll")
        .demoPress(rule.map { "reviewAll.\($0)" } ?? "reviewAll") { start(ready) }
        .sheet(item: $review) { out in ReviewSheet(plan: plan, dryRun: out) }
    }

    private func start(_ ready: [CleanPick]) {
        Task {
            busy = true
            plan = ready
            review = await model.clean(plan, execute: false)
            busy = false
        }
    }
}
