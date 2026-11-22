import Foundation
import AppKit
import Observation
import CleanCore
import AgentEngine

/// App state. Every change to files goes through `engine` (ADR 0002, 0005);
/// nothing here moves or deletes anything itself.
@MainActor
@Observable
final class AppModel {
    enum Screen: String, CaseIterable, Identifiable {
        case overview, projects, caches, history, devStack
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .projects: "Projects"
            case .caches: "Caches"
            case .history: "History"
            case .devStack: "Dev Stack"
            }
        }
        var symbol: String {
            switch self {
            case .overview: "sparkles"
            case .projects: "folder"
            case .caches: "internaldrive"
            case .history: "clock.arrow.circlepath"
            case .devStack: "shippingbox"
            }
        }
    }

    var screen: Screen = .overview
    /// The first-run guide is showing.
    var onboarding = false
    var selectedProject: String?

    // Scan
    private(set) var projects: [Project] = []
    private(set) var skipped: [SkippedFolder] = []
    private(set) var summary: ScanSummary?
    private(set) var scanning = false
    private(set) var lastScan: Date?
    private var scanTask: Task<Void, Never>?

    // History, settings, inventory
    private(set) var runs: [Run] = []
    private(set) var config: ConfigOutput?
    private(set) var devStack: [DevStackItem] = []
    private(set) var devStackLoading = false
    private(set) var caches: [ToolCache] = []
    private(set) var cachesLoading = false

    var error: String?
    #if DEBUG
    /// The button the README demo presses next (DemoWalkthrough).
    var demoPress: String?
    #endif

    let engine: Engine?

    /// Folders the scan starts from when it is not scanning the whole Mac.
    var scanRoots: [String] {
        didSet { UserDefaults.standard.set(scanRoots, forKey: "scanRoots") }
    }

    /// Scan every folder on this Mac's own disk (the default), not only `scanRoots`.
    var wholeDisk: Bool {
        didSet { UserDefaults.standard.set(wholeDisk, forKey: "wholeDisk") }
    }

    /// Whether macOS gave the app Full Disk Access; checked again on activation.
    private(set) var fullDiskAccess = FullDiskAccess.granted
    func recheckAccess() { fullDiskAccess = FullDiskAccess.granted }

    /// Folders the last scan could not read because of macOS privacy settings.
    var privacyBlocked: Int { skipped.filter { $0.reason == .protected }.count }

    /// Quarantined runs are purged after this many days, freeing their space; 0 keeps them until purged by hand.
    var autoFreeDays: Int {
        didSet { UserDefaults.standard.set(autoFreeDays, forKey: "autoFreeDays") }
    }

    /// With the whole Mac: also local external drives.
    var otherDrives: Bool {
        didSet { UserDefaults.standard.set(otherDrives, forKey: "otherDrives") }
    }

    /// Rescan in the background when the app opens and the last scan is over an hour old.
    var scanOnOpen: Bool {
        didSet { UserDefaults.standard.set(scanOnOpen, forKey: "scanOnOpen") }
    }

    /// Scheduled clean (P5), off by default.
    var autoClean: AutoClean {
        didSet {
            UserDefaults.standard.set(autoClean.rawValue, forKey: "autoClean")
            if autoClean != .off { Scheduler.askToNotify() }
        }
    }

    /// The most a scheduled clean takes, in GB.
    var autoCleanCapGB: Int {
        didSet { UserDefaults.standard.set(autoCleanCapGB, forKey: "autoCleanCapGB") }
    }

    private(set) var lastAutoClean: Date? {
        didSet { UserDefaults.standard.set(lastAutoClean, forKey: "lastAutoClean") }
    }

    private var scheduler: Scheduler?

    /// Space the last automatic purge gave back, to show once.
    private(set) var autoFreed: UInt64 = 0

    /// Tests and the QA walkthrough pass -scanRoots: no scan or purge starts on its own.
    private let testRun = ProcessInfo.processInfo.arguments.contains("-scanRoots")

    /// What the scan covers, for people.
    var scanScope: String {
        wholeDisk ? (otherDrives ? "your whole Mac and other drives" : "your whole Mac") : scanRoots.map { tildePath($0) }.joined(separator: ", ")
    }

    init() {
        engine = Self.locateEngine().map { Engine(binary: $0) }
        scanRoots = UserDefaults.standard.stringArray(forKey: "scanRoots") ?? [CMConstants.homePath]
        // Tests and the QA walkthrough pass -scanRoots: scan only those.
        // bool(forKey:) also reads a "-wholeDisk YES" launch argument.
        wholeDisk = UserDefaults.standard.object(forKey: "wholeDisk") != nil
            ? UserDefaults.standard.bool(forKey: "wholeDisk")
            : !ProcessInfo.processInfo.arguments.contains("-scanRoots")
        autoFreeDays = UserDefaults.standard.object(forKey: "autoFreeDays") as? Int ?? 7
        otherDrives = UserDefaults.standard.bool(forKey: "otherDrives")
        scanOnOpen = UserDefaults.standard.object(forKey: "scanOnOpen") as? Bool ?? true
        autoClean = AutoClean(rawValue: UserDefaults.standard.string(forKey: "autoClean") ?? "") ?? .off
        autoCleanCapGB = UserDefaults.standard.object(forKey: "autoCleanCapGB") as? Int ?? 10
        lastAutoClean = UserDefaults.standard.object(forKey: "lastAutoClean") as? Date
        restoreSavedScan()
        if !testRun && engine != nil { scheduler = Scheduler(model: self) }
        if engine == nil { error = "The engine is missing from the app bundle. Reinstall OpenSweep." }
    }

    /// The bundled binary, or OPENSWEEP_BIN in Debug builds. Release builds
    /// never take the engine path from the environment: the engine runs with
    /// the app's Full Disk Access.
    static func locateEngine() -> URL? {
        #if DEBUG
        if let dev = ProcessInfo.processInfo.environment["OPENSWEEP_BIN"] {
            return URL(fileURLWithPath: dev)
        }
        #endif
        // Contents/Helpers: Contents/MacOS ignores case and holds OpenSweep.
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/opensweep")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    // MARK: Scan

    var cleanable: [Project] {
        projects.filter { p in p.items.contains(where: Selection.selectable) }
            .sorted { total($0) > total($1) }
    }

    func total(_ p: Project) -> UInt64 { p.items.reduce(0) { $0 + ($1.bytes ?? 0) } }

    func project(_ root: String?) -> Project? { projects.first { $0.root == root } }

    func toggleScan() {
        if scanning { scanTask?.cancel(); return }
        guard let engine else { return }
        scanning = true
        projects = []
        skipped = []
        summary = nil
        let roots = wholeDisk ? [] : scanRoots.map { URL(fileURLWithPath: $0) }
        let whole = wholeDisk
        let drives = wholeDisk && otherDrives
        scanTask = Task {
            do {
                for try await event in engine.scan(roots: roots, wholeDisk: whole, otherDrives: drives) {
                    switch event {
                    case .project(let p): projects.append(p)
                    case .skipped(let path, let reason, let detail): skipped.append(SkippedFolder(path: path, detail: detail, reason: reason))
                    case .summary(let s): summary = s
                    }
                }
                lastScan = Date()
                saveScan()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { fail(error) }
            }
            scanning = false
        }
    }

    /// Re-reads one project after a clean, restore or pin.
    func refresh(_ root: String, persist: Bool = true) async {
        guard let engine else { return }
        do {
            let fresh = try await engine.plan(project: URL(fileURLWithPath: root)).project
            if let i = projects.firstIndex(where: { $0.root == root }) { projects[i] = fresh }
        } catch {
            // A project whose folder is gone leaves the list; any other
            // failure keeps it and says what went wrong.
            if FileManager.default.fileExists(atPath: root) { fail(error) } else { projects.removeAll { $0.root == root } }
        }
        if persist { settle() }
    }

    /// Totals and the saved scan follow the projects after they change.
    private func settle() {
        if summary != nil { summary = ScanSummary(totalling: projects) }
        saveScan()
    }

    /// Starts a background rescan when the saved one is over an hour old.
    /// The first scan is always the person's choice.
    func scanIfStale() {
        guard !testRun, scanOnOpen, !scanning, let last = lastScan, last.timeIntervalSinceNow < -3600 else { return }
        toggleScan()
    }

    // MARK: Saved scan

    /// The last scan, so the app opens with results instead of an empty screen.
    private struct SavedScan: Codable {
        let scope: String
        let date: Date
        let projects: [Project]
        let skipped: [SkippedFolder]
        let summary: ScanSummary?
    }

    private var scopeKey: String {
        wholeDisk ? (otherDrives ? "whole-disk+drives" : "whole-disk") : scanRoots.joined(separator: "\n")
    }

    private static var savedScanURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? CMConstants.homePath
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/OpenSweep/last-scan.json")
    }

    private func saveScan() {
        guard lastScan != nil else { return }
        let saved = SavedScan(scope: scopeKey, date: lastScan ?? Date(), projects: projects, skipped: skipped, summary: summary)
        do {
            let url = Self.savedScanURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        } catch {
            // ponytail: a scan that cannot be saved still works; it is only rescanned next launch.
        }
    }

    /// Reads the saved scan if it covered what is chosen now.
    private func restoreSavedScan() {
        guard !testRun, let data = try? Data(contentsOf: Self.savedScanURL),
              let saved = try? JSONDecoder().decode(SavedScan.self, from: data),
              saved.scope == scopeKey else { return }
        projects = saved.projects
        skipped = saved.skipped
        summary = saved.summary
        lastScan = saved.date
    }

    // MARK: Scheduled clean

    /// Runs the scheduled clean when it is due: rescan, then one run of what
    /// `Selection.scheduled` takes. The engine re-checks every folder.
    func runScheduleIfDue(now: Date = Date()) async {
        guard !testRun, let interval = autoClean.interval, !scanning else { return }
        if let last = lastAutoClean, now.timeIntervalSince(last) < interval { return }
        // This scan's own outcome decides, not an older error still on screen.
        let before = lastScan
        toggleScan()
        await scanTask?.value
        guard lastScan != before, summary != nil else { return }
        lastAutoClean = now
        guard let run = await runSchedule(cap: UInt64(max(autoCleanCapGB, 1)) * 1_000_000_000) else { return }
        let moved = run.entries.filter { $0.state == .moved }
        Scheduler.notify(freed: moved.reduce(0) { $0 + $1.bytes },
                         projects: Set(moved.map(\.projectRoot)).count,
                         run: run.runId, freesOn: freesOn)
    }

    /// One scheduled clean over the current scan; nil when nothing moved.
    func runSchedule(cap: UInt64) async -> Run? {
        let plan = Selection.scheduled(projects, cap: cap).compactMap { s in
            project(s.root).map { CleanPick(project: $0, picked: Set(s.paths)) }
        }
        guard !plan.isEmpty, let run = await clean(plan, execute: true)?.run,
              run.entries.contains(where: { $0.state == .moved }) else { return nil }
        return run
    }

    /// Undo from a notification.
    func undoRun(_ id: String) async {
        await loadHistory()
        if let run = runs.first(where: { $0.runId == id }) { await restore(run) }
    }

    // MARK: Free space

    /// Purges quarantined runs older than `autoFreeDays`, through the engine.
    func freeExpired() async {
        guard !testRun, autoFreeDays > 0, let engine else { return }
        do {
            let out = try await engine.purge(olderThanDays: autoFreeDays, execute: true)
            if out.freed > 0 {
                autoFreed = out.freed
                await loadHistory()
            }
        } catch {
            fail(error)
        }
    }

    /// When a clean made today gives its space back on its own, if it does.
    var freesOn: Date? {
        autoFreeDays > 0 ? Calendar.current.date(byAdding: .day, value: autoFreeDays, to: Date()) : nil
    }

    /// What "clean everything ready" takes: the folders each project starts
    /// with ticked (Safe, allowed, not active or pinned), optionally one language's.
    func readyPlan(rule: String? = nil) -> [CleanPick] {
        projects.compactMap { p in
            var picked = Selection.defaults(for: p)
            if let rule {
                let ofRule = Set(p.items.filter { $0.rule == rule }.map { Selection.path($0, in: p) })
                picked.formIntersection(ofRule)
            }
            return picked.isEmpty ? nil : CleanPick(project: p, picked: picked)
        }
    }

    // MARK: Clean

    /// A dry run of exactly `picked` in `project`.
    func review(_ picked: Set<String>, in project: Project) async -> CleanOutput? {
        await clean(picked, in: project, execute: false)
    }

    func clean(_ picked: Set<String>, in project: Project, execute: Bool) async -> CleanOutput? {
        await clean([CleanPick(project: project, picked: picked)], execute: execute)
    }

    /// One engine run over several projects, so a single Undo restores them all.
    func clean(_ plan: [CleanPick], execute: Bool) async -> CleanOutput? {
        let plan = plan.filter { !$0.picked.isEmpty }
        guard let engine, !plan.isEmpty else { return nil }
        let caution = plan.contains { Selection.flags(for: $0.picked, in: $0.project).caution }
        let active = plan.contains { $0.project.verdict == .active }
        do {
            let out = try await engine.clean(
                projects: plan.map { URL(fileURLWithPath: $0.project.root) },
                only: plan.flatMap(\.picked).sorted().map { URL(fileURLWithPath: $0) },
                includeCaution: caution,
                includeActive: active,
                execute: execute)
            if execute {
                for pick in plan { await refresh(pick.project.root, persist: false) }
                settle()
                await loadHistory()
            }
            return out
        } catch {
            fail(error)
            return nil
        }
    }

    // MARK: History

    func loadHistory() async {
        guard let engine else { return }
        do { runs = try await engine.history() } catch { fail(error) }
    }

    func restore(_ run: Run, item: Int? = nil) async {
        guard let engine else { return }
        do {
            let back = try await engine.restore(run: run.runId, item: item)
            await loadHistory()
            for root in Set(back.entries.map(\.projectRoot)) { await refresh(root, persist: false) }
            settle()
            if let stuck = back.entries.first(where: { $0.state == .moved && $0.note != nil }) {
                error = "Some folders stayed in quarantine: \(stuck.note ?? "")"
            }
        } catch {
            fail(error)
        }
    }

    var stats: Stats { Stats(runs: runs) }

    /// Purges every run at least `days` old; a dry run unless `execute`. Returns the bytes.
    func purge(olderThanDays days: Int, execute: Bool) async -> UInt64? {
        guard let engine else { return nil }
        do {
            let out = try await engine.purge(olderThanDays: days, execute: execute)
            if execute { await loadHistory() }
            return execute ? out.freed : out.bytes
        } catch {
            fail(error)
            return nil
        }
    }

    /// What purging would free, without deleting.
    func purgePreview(_ run: Run) async -> UInt64? {
        guard let engine else { return nil }
        return try? await engine.purge(run: run.runId).bytes
    }

    func purge(_ run: Run) async {
        guard let engine else { return }
        do {
            _ = try await engine.purge(run: run.runId, execute: true)
            await loadHistory()
        } catch {
            fail(error)
        }
    }

    // MARK: Settings

    func loadConfig() async {
        guard let engine else { return }
        do { config = try await engine.config() } catch { fail(error) }
    }

    func setDays(idle: Int, dormant: Int) async {
        guard let engine else { return }
        do { config = try await engine.config(idleDays: idle, dormantDays: dormant) } catch { fail(error) }
    }

    func exclude(_ folder: URL) async {
        guard let engine else { return }
        do { config = try await engine.config(exclude: [folder]) } catch { fail(error) }
    }

    func include(_ folder: String) async {
        guard let engine else { return }
        do { config = try await engine.config(include: [URL(fileURLWithPath: folder)]) } catch { fail(error) }
    }

    func setPinned(_ root: String, _ pinned: Bool, days: Int? = nil, remote: Bool = false) async {
        guard let engine else { return }
        do {
            let url = URL(fileURLWithPath: root)
            _ = pinned ? try await engine.pin(url, days: days, remote: remote) : try await engine.unpin(url)
            await loadConfig()
            await refresh(root)
        } catch {
            fail(error)
        }
    }

    // MARK: Global caches (ADR 0006)

    func loadCaches() async {
        guard let engine, !cachesLoading else { return }
        cachesLoading = true
        defer { cachesLoading = false }
        do { caches = try await engine.caches() } catch { fail(error) }
    }

    /// Runs each tool's own command. Not undoable; the caller has asked first.
    func clearCaches(_ ids: [String]) async -> [ToolCache] {
        guard let engine, !ids.isEmpty else { return [] }
        do {
            let out = try await engine.cleanCaches(ids, execute: true)
            await loadCaches()
            return out.caches
        } catch {
            fail(error)
            return []
        }
    }

    // MARK: Dev Stack (read-only)

    func loadDevStack() {
        guard !devStackLoading else { return }
        devStackLoading = true
        Task {
            devStack = await DevStackInventory.collect()
            devStackLoading = false
        }
    }

    /// Shows an engine error, unless the work was only cancelled.
    private func fail(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return }
        self.error = describe(error)
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case EngineError.failed(let m): m
        case EngineError.badOutput(let m): "Unexpected output from the engine: \(m)"
        case EngineError.launch(let m): "The engine could not start: \(m)"
        default: error.localizedDescription
        }
    }
}

/// Full Disk Access lets one scan read every folder without macOS asking
/// separately for Desktop, Documents, Downloads and other drives. Only the
/// person can grant it, in System Settings.
enum FullDiskAccess {
    /// macOS lets only apps with Full Disk Access open the privacy database.
    static var granted: Bool {
        let db = CMConstants.homePath + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: db) else { return false }
        try? handle.close()
        return true
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SkippedFolder: Codable, Hashable {
    let path: String
    let detail: String
    /// Missing in summaries saved by older versions.
    var reason: SkipReason? = nil
}

/// Folders ticked in one project, for a clean.
struct CleanPick: Hashable {
    let project: Project
    let picked: Set<String>
}
