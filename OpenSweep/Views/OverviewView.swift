import SwiftUI
import AgentEngine

/// One language's share of the disk, across every scanned project.
struct LanguageStat: Identifiable {
    let ecosystem: Ecosystem
    var ready: UInt64 = 0
    var caution: UInt64 = 0
    var active: UInt64 = 0
    var folders = 0
    var projects: [(project: Project, bytes: UInt64)] = []
    var id: String { ecosystem.id }
    var total: UInt64 { ready + caution + active }

    /// Pinned projects and folders the guard refuses are left out.
    static func of(_ projects: [Project]) -> [LanguageStat] {
        var by: [String: LanguageStat] = [:]
        for p in projects where !p.pinned {
            var perRule: [String: UInt64] = [:]
            for i in p.items where i.refused == nil {
                let b = i.bytes ?? 0
                var s = by[i.rule] ?? LanguageStat(ecosystem: .of(rule: i.rule))
                if p.verdict == .active { s.active += b } else if i.kind == .safe { s.ready += b } else { s.caution += b }
                s.folders += 1
                by[i.rule] = s
                perRule[i.rule, default: 0] += b
            }
            for (rule, b) in perRule { by[rule]?.projects.append((p, b)) }
        }
        return by.values.filter { $0.total > 0 }
            .map { var s = $0; s.projects.sort { $0.bytes > $1.bytes }; return s }
            .sorted { $0.total > $1.total }
    }
}

/// Home: where the disk went, language by language.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: String?
    @State private var opened: String?
    @AppStorage("accessBannerDismissed") private var accessDismissed = false
    @AppStorage(Peep.showKey) private var showCharacter = true

    var body: some View {
        let stats = LanguageStat.of(model.projects)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                host(stats).entrance(0, from: .top)
                if model.wholeDisk && !model.fullDiskAccess && (!accessDismissed || model.privacyBlocked > 0) {
                    AccessBanner(blocked: model.privacyBlocked) { accessDismissed = true }
                        .entrance(1)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if model.summary == nil && !model.scanning {
                    welcome.entrance(1)
                } else {
                    hero(stats).entrance(1)
                    if showCharacter && model.stats.cleaned > 0 { CleanedSoFar(stats: model.stats).entrance(2) }
                    languages(stats)
                    if let id = opened, let s = stats.first(where: { $0.id == id }) {
                        LanguageDrawer(stat: s) { opened = nil }
                            .id(id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                }
                if model.summary != nil && !stats.isEmpty {
                    SpaceFlow(stats: stats, hovered: $hovered).entrance(3)
                    DiskMap(stats: stats).entrance(3)
                }
                skippedFolders
            }
            .padding(.horizontal, 36).padding(.vertical, 30)
            .frame(maxWidth: 1440, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: opened)
        }
    }

    // MARK: Host

    private func host(_ stats: [LanguageStat]) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Peep(mood: mood(stats), size: 88, backdrop: hovered.flatMap { h in stats.first { $0.id == h }?.ecosystem.color } ?? Brand.teal)
            SpeechBubble(text: line(stats))
                .frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 16)
            Button(model.scanning ? "Stop" : (model.lastScan == nil ? "Scan projects" : "Scan again")) {
                model.toggleScan()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("scan")
            .demoPress("scan") { model.toggleScan() }
        }
    }

    private func mood(_ stats: [LanguageStat]) -> Peep.Mood {
        if hovered != nil { return .wow }
        if model.scanning { return .talk }
        guard let s = model.summary else { return .calm }
        return s.ready.bytes > 0 ? .happy : .lol
    }

    private func line(_ stats: [LanguageStat]) -> String {
        let roots = model.scanScope
        if model.scanning { return "Digging through \(roots)…" }
        guard let s = model.summary else {
            return "Hi! Scan your projects and I'll show where your disk went, language by language."
        }
        guard let top = stats.first else { return "All tidy. Nothing to clean right now." }
        let milestone = (showCharacter ? Stats.milestone(for: model.stats.cleaned) : nil).map { " We have cleared over \(bytes($0)) together." } ?? ""
        if s.ready.bytes == 0 { return "\(top.ecosystem.name) holds the most, but nothing can go without a reinstall.\(milestone)" }
        return "\(bytes(s.ready.bytes)) can go right now. \(top.ecosystem.name) is the hungriest, at \(bytes(top.total)).\(milestone)"
    }

    // MARK: Before the first scan

    private var welcome: some View {
        HStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your disk, by language").font(.system(size: 40, weight: .bold)).tracking(-0.8).foregroundStyle(Brand.text)
                    .accessibilityAddTraits(.isHeader)
                Text("A scan reads your project folders and measures build output, dependencies and caches. It changes nothing. Cleaning moves folders to a quarantine you can undo.")
                    .font(.title3).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    SettingsLink { Text("Choose folders…") }.buttonStyle(SecondaryButtonStyle())
                    Text("Scans \(model.scanScope)")
                        .font(.callout).foregroundStyle(Brand.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            Spacer(minLength: 0)
            LogoOrbit().frame(width: 300, height: 300)
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 24)
    }

    // MARK: Hero

    private func hero(_ stats: [LanguageStat]) -> some View {
        let found = stats.reduce(0) { $0 + $1.total }
        return HStack(alignment: .center, spacing: 36) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.summary == nil ? "Found so far" : "Ready to clean").font(.headline).foregroundStyle(Brand.muted)
                Group {
                    if let s = model.summary {
                        Text(bytes(s.ready.bytes))
                            .contentTransition(.numericText(value: Double(s.ready.bytes)))
                            .accessibilityIdentifier("ready.bytes")
                    } else {
                        Text(bytes(found)).contentTransition(.numericText(value: Double(found)))
                    }
                }
                .font(.figure(68)).foregroundStyle(Brand.text)
                .animation(.spring(response: 0.6), value: found)
                if let s = model.summary {
                    Text("\(s.ready.folders) folders that rebuild on their own, across \(stats.count) \(stats.count == 1 ? "language" : "languages").")
                        .font(.title3).foregroundStyle(Brand.muted)
                    HStack(spacing: 8) {
                        ReviewAllButton()
                        if s.caution.bytes > 0 { StatusChip(text: "\(bytes(s.caution.bytes)) needs a reinstall", systemImage: "exclamationmark.triangle.fill", tint: Brand.amber) }
                        if s.active.bytes > 0 { StatusChip(text: "\(bytes(s.active.bytes)) in active projects", systemImage: "bolt.fill", tint: Brand.sky) }
                    }
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Brand.teal).frame(width: 260)
                    Text("\(model.projects.count) projects so far").font(.title3).foregroundStyle(Brand.muted)
                        .contentTransition(.numericText(value: Double(model.projects.count)))
                        .animation(.spring, value: model.projects.count)
                }
            }
            Spacer(minLength: 0)
            LanguageRing(stats: stats, highlighted: hovered)
                .frame(width: 230, height: 230)
        }
        .padding(30)
        .glassCard(radius: 24)
    }

    // MARK: Languages

    private func languages(_ stats: [LanguageStat]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("By language").font(.title2.bold()).foregroundStyle(Brand.text).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Pick one to see its projects").font(.callout).foregroundStyle(Brand.muted)
            }
            .entrance(2)
            let biggest = stats.first?.total ?? 1
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                ForEach(Array(stats.enumerated()), id: \.element.id) { i, s in
                    Button {
                        opened = opened == s.id ? nil : s.id
                    } label: {
                        LanguageCard(stat: s, share: Double(s.total) / Double(max(biggest, 1)), open: opened == s.id, index: i)
                            .hoverLift(s.ecosystem.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("language.\(s.id)")
                    .accessibilityLabel("\(s.ecosystem.name), \(bytes(s.total)) in \(s.projects.count) projects")
                    .onHover { hovered = $0 ? s.id : (hovered == s.id ? nil : hovered) }
                    .entrance(3 + i)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Languages")
        }
    }

    @ViewBuilder
    private var skippedFolders: some View {
        if !model.skipped.isEmpty {
            DisclosureGroup("\(model.skipped.count) folders were not scanned") {
                ForEach(model.skipped, id: \.path) { s in
                    HStack {
                        Text(tildePath(s.path)).font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(s.detail).font(.caption)
                    }
                    .foregroundStyle(Brand.muted)
                }
            }
            .foregroundStyle(Brand.muted)
        }
    }
}

// MARK: - Pieces

/// A language: logo, size, and how much of it can go now.
struct LanguageCard: View {
    let stat: LanguageStat
    let share: Double
    let open: Bool
    let index: Int
    @State private var float = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let c = stat.ecosystem.color
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                EcosystemBadge(ecosystem: stat.ecosystem, size: 48)
                    .offset(y: float ? -4 : 0)
                    .rotationEffect(.degrees(float ? -8 : 0))
                Spacer()
                Image(systemName: open ? "chevron.up.circle.fill" : "chevron.down.circle")
                    .font(.title3).foregroundStyle(open ? c : Brand.muted)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.ecosystem.name).font(.title3.weight(.semibold)).foregroundStyle(Brand.text)
                Text("\(stat.projects.count) \(stat.projects.count == 1 ? "project" : "projects"), \(stat.folders) \(stat.folders == 1 ? "folder" : "folders")")
                    .font(.callout).foregroundStyle(Brand.muted)
            }
            Text(bytes(stat.total)).font(.figure(30)).foregroundStyle(Brand.text)
            SplitBar(stat: stat, share: share)
            HStack(spacing: 12) {
                legend("Ready", stat.ready, Brand.green)
                if stat.caution > 0 { legend("Reinstall", stat.caution, Brand.amber) }
                if stat.active > 0 { legend("Active", stat.active, Brand.sky) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(open ? c.opacity(0.08) : .clear)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.surface)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(open ? c.opacity(0.7) : Brand.hairline, lineWidth: open ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { h in withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { float = h && !reduce } }
    }

    private func legend(_ name: String, _ n: UInt64, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text("\(name) \(bytes(n))").font(.caption).foregroundStyle(Brand.muted).monospacedDigit()
        }
    }
}

/// Ready, reinstall and active, growing in from the left.
struct SplitBar: View {
    let stat: LanguageStat
    let share: Double
    @State private var grown = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width * (grown ? max(share, 0.04) : 0)
            let t = Double(max(stat.total, 1))
            HStack(spacing: 2) {
                if stat.ready > 0 { Capsule().fill(Brand.green).frame(width: max(3, w * Double(stat.ready) / t)) }
                if stat.caution > 0 { Hatch(color: Brand.amber).clipShape(Capsule()).frame(width: max(3, w * Double(stat.caution) / t)) }
                if stat.active > 0 { Capsule().strokeBorder(Brand.sky, lineWidth: 1.5).frame(width: max(3, w * Double(stat.active) / t)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Capsule().fill(Brand.hairline.opacity(0.6)))
        }
        .frame(height: 8)
        .accessibilityHidden(true)
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(0.25)) { grown = true } }
    }
}

/// Every language's footprint as a ring that draws itself in.
struct LanguageRing: View {
    let stats: [LanguageStat]
    let highlighted: String?
    @State private var progress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let total = Double(max(stats.reduce(0) { $0 + $1.total }, 1))
        let segments: [(LanguageStat, Double, Double)] = stats.reduce(into: []) { acc, s in
            let start = acc.last?.2 ?? 0
            acc.append((s, start, start + Double(s.total) / total))
        }
        ZStack {
            Circle().stroke(Brand.hairline.opacity(0.7), lineWidth: 22)
            Circle().stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
                .foregroundStyle(Brand.slate.opacity(0.35))
                .padding(-22)
            ForEach(segments, id: \.0.id) { s, start, end in
                let lit = highlighted == nil || highlighted == s.id
                Circle()
                    .trim(from: start * progress, to: max(start, end - 0.006) * progress)
                    .stroke(s.ecosystem.color, style: StrokeStyle(lineWidth: highlighted == s.id ? 32 : 22, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .opacity(lit ? 1 : 0.3)
            }
            VStack(spacing: 4) {
                if let h = highlighted, let s = stats.first(where: { $0.id == h }) {
                    EcosystemBadge(ecosystem: s.ecosystem, size: 40)
                    Text(bytes(s.total)).font(.figure(22)).foregroundStyle(Brand.text)
                    Text(s.ecosystem.name).font(.caption).foregroundStyle(Brand.muted)
                } else {
                    Text(bytes(UInt64(total))).font(.figure(26)).foregroundStyle(Brand.text)
                        .contentTransition(.numericText(value: total))
                    Text("measured").font(.callout).foregroundStyle(Brand.muted)
                }
            }
            .transition(.scale.combined(with: .opacity))
            .id(highlighted ?? "all")
        }
        .padding(22)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: highlighted)
        .animation(.spring(response: 0.6), value: total)
        .accessibilityElement()
        .accessibilityLabel("Space by language")
        .accessibilityAddTraits(.isImage)
        .accessibilityValue(stats.map { "\($0.ecosystem.name) \(bytes($0.total))" }.joined(separator: ", "))
        .onAppear {
            withAnimation(reduce ? .none : .easeOut(duration: 1.2).delay(0.2)) { progress = 1 }
        }
    }
}

/// The projects behind one language, with a character to say so.
struct LanguageDrawer: View {
    @Environment(AppModel.self) private var model
    let stat: LanguageStat
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Peep(crew: stat.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 5 + 1, size: 56, backdrop: stat.ecosystem.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(stat.ecosystem.name) lives in \(stat.projects.count) \(stat.projects.count == 1 ? "project" : "projects")")
                        .font(.title3.weight(.semibold)).foregroundStyle(Brand.text)
                    Text("Open one to choose what to clean.").font(.callout).foregroundStyle(Brand.muted)
                }
                Spacer()
                ReviewAllButton(rule: stat.id, title: "Review all \(stat.ecosystem.name)")
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Close \(stat.ecosystem.name)")
            }
            let biggest = stat.projects.first?.bytes ?? 1
            VStack(spacing: 0) {
                ForEach(Array(stat.projects.enumerated()), id: \.element.project.root) { i, row in
                    Button {
                        model.selectedProject = row.project.root
                        model.screen = .projects
                    } label: {
                        ProjectRow(project: row.project, total: row.bytes, share: Double(row.bytes) / Double(max(biggest, 1)))
                    }
                    .buttonStyle(RowButtonStyle())
                    .entrance(i)
                    if i < stat.projects.count - 1 { Divider().overlay(Brand.hairline).padding(.leading, 64) }
                }
            }
            .glassCard()
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(stat.ecosystem.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(stat.ecosystem.color.opacity(0.35)))
    }
}

/// Language logos circling the host before the first scan.
struct LogoOrbit: View {
    private let ids = ["node", "rust", "python", "go", "swiftpm", "flutter", "java", "php", "dotnet", "android", "xcode"]

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2 - 26
            ZStack {
                Ambient { t in
                    let turn = t / 50 * 360
                    ZStack {
                        ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                            let a = Double(i) / Double(ids.count) * 2 * .pi
                            EcosystemBadge(ecosystem: .of(rule: id), size: 38)
                                .rotationEffect(.degrees(-turn))
                                .offset(x: r * cos(a), y: r * sin(a))
                        }
                    }
                    .rotationEffect(.degrees(turn))
                }
                Circle().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 7])).foregroundStyle(Brand.slate.opacity(0.35)).padding(26)
                Circle().stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 9])).foregroundStyle(Brand.slate.opacity(0.2)).padding(80)
                Peep(mood: .calm, size: 120, backdrop: Brand.teal)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// Diagonal stripes for space that needs a reinstall.
struct Hatch: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.18)))
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(p, with: .color(color.opacity(0.85)), lineWidth: 1.5)
                x += 6
            }
        }
    }
}

/// A full-width row that highlights on hover and press.
struct RowButtonStyle: ButtonStyle {
    var selected = false
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Brand.teal.opacity(0.12) : (configuration.isPressed ? Brand.raised : (hover ? Brand.raised.opacity(0.6) : .clear)))
                    .padding(2))
            .offset(x: hover && !selected ? 3 : 0)
            .animation(.spring(response: 0.3), value: hover)
            .onHover { hover = $0 }
    }
}

struct ProjectRow: View {
    let project: Project
    let total: UInt64
    var share: Double = 0

    var body: some View {
        HStack(spacing: 14) {
            EcosystemStack(ecosystems: project.ecosystems.isEmpty ? [Ecosystem.of(rule: "")] : project.ecosystems)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: project.root).lastPathComponent).font(.body.weight(.semibold)).foregroundStyle(Brand.text)
                Text(tildePath(project.root))
                    .font(.caption.monospaced()).foregroundStyle(Brand.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if project.pinned {
                StatusChip(text: "Pinned", systemImage: "pin.fill", tint: Brand.slate)
            } else {
                StatusChip(text: project.verdict.label, systemImage: project.verdict.symbol, tint: project.verdict.tint)
            }
            VStack(alignment: .trailing, spacing: 5) {
                Text(total == 0 ? "—" : bytes(total)).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Brand.text)
                ShareBar(share: share, tint: project.ecosystems.first?.color ?? Brand.teal).frame(width: 72)
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Asks once for Full Disk Access, so a whole-Mac scan needs no other prompt.
struct AccessBanner: View {
    let blocked: Int
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Peep(crew: 4, size: 52, backdrop: Brand.amber)
            VStack(alignment: .leading, spacing: 4) {
                Text("Let one scan reach every folder").font(.headline).foregroundStyle(Brand.text)
                Text(blocked > 0
                     ? "macOS kept \(blocked) \(blocked == 1 ? "folder" : "folders") private in the last scan. Give OpenSweep Full Disk Access once and it never needs to ask again. It only reads; cleaning still asks you first."
                     : "macOS asks separately for Desktop, Documents, Downloads and other drives. Give OpenSweep Full Disk Access once and it never needs to ask again. It only reads; cleaning still asks you first.")
                    .font(.callout).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
                .buttonStyle(PrimaryButtonStyle(tint: Brand.amber))
                .accessibilityIdentifier("access.open")
            if blocked == 0 {
                Button("Not now", action: dismiss).buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("access.later")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.amber.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.amber.opacity(0.35)))
    }
}

/// What OpenSweep has cleaned on this Mac, from History. Local only.
struct CleanedSoFar: View {
    let stats: Stats

    var body: some View {
        let top = stats.byRule.sorted { $0.value > $1.value }.prefix(4)
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cleaned so far").font(.headline).foregroundStyle(Brand.muted)
                Text(bytes(stats.cleaned)).font(.figure(36)).foregroundStyle(Brand.text)
                    .contentTransition(.numericText(value: Double(stats.cleaned)))
                Text("\(bytes(stats.freed)) freed for good, \(bytes(stats.freedThisMonth)) this month. \(bytes(stats.held)) still held, so you can undo it.")
                    .font(.callout).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 380, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                ForEach(Array(top), id: \.key) { rule, b in
                    VStack(spacing: 6) {
                        EcosystemBadge(ecosystem: .of(rule: rule), size: 34)
                        Text(bytes(b)).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Brand.text)
                        Text(Ecosystem.of(rule: rule).name).font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
                    }
                    .frame(minWidth: 72)
                }
            }
        }
        .padding(24)
        .glassCard(radius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("cleanedSoFar")
    }
}

/// Read-only map of the space found: one block per language, split by project.
struct DiskMap: View {
    @Environment(AppModel.self) private var model
    let stats: [LanguageStat]
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk map").font(.title2.bold()).foregroundStyle(Brand.text).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(hovered ?? "Each block is a project; pick one to open it")
                    .font(.callout).foregroundStyle(Brand.muted).lineLimit(1).truncationMode(.middle)
            }
            GeometryReader { g in
                let outer = Treemap.squarify(stats.map { Double($0.total) }, in: CGRect(origin: .zero, size: g.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(stats.enumerated()), id: \.element.id) { i, s in
                        language(s, in: outer[i].insetBy(dx: 2, dy: 2))
                    }
                }
            }
            .frame(height: 320)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Disk map")
        }
    }

    private func language(_ s: LanguageStat, in r: CGRect) -> some View {
        let shown = Array(s.projects.prefix(12))
        let inner = Treemap.squarify(shown.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: r.size).insetBy(dx: 3, dy: 3))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(s.ecosystem.color.opacity(0.10))
            ForEach(Array(shown.enumerated()), id: \.element.project.root) { j, row in
                let t = inner[j].insetBy(dx: 1.5, dy: 1.5)
                let name = URL(fileURLWithPath: row.project.root).lastPathComponent
                Button {
                    model.selectedProject = row.project.root
                    model.screen = .projects
                } label: {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(s.ecosystem.color.opacity(hovered == name ? 0.55 : 0.30))
                        if t.width > 70 && t.height > 34 {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(bytes(row.bytes)).font(.caption2).monospacedDigit().opacity(0.8)
                            }
                            .foregroundStyle(Brand.text).padding(6)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: max(t.width, 0), height: max(t.height, 0))
                .offset(x: t.minX, y: t.minY)
                .onHover { hovered = $0 ? "\(name): \(s.ecosystem.name), \(bytes(row.bytes))" : nil }
                .help("\(name), \(bytes(row.bytes))")
                .accessibilityLabel("\(name), \(s.ecosystem.name), \(bytes(row.bytes))")
            }
            if r.width > 40 && r.height > 40 {
                EcosystemBadge(ecosystem: s.ecosystem, size: 22).padding(6)
                    .frame(width: r.width, height: r.height, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: max(r.width, 0), height: max(r.height, 0))
        .offset(x: r.minX, y: r.minY)
        .animation(.spring(response: 0.4), value: hovered)
    }
}
