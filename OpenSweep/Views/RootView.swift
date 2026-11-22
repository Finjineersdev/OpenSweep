import SwiftUI
import AgentEngine

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppModel.Screen.allCases, selection: Binding(get: { model.screen }, set: { if let s = $0 { model.screen = s } })) { screen in
                Label {
                    Text(screen.title)
                } icon: {
                    Image(systemName: screen.symbol)
                        .symbolEffect(.bounce, value: model.screen == screen)
                }
                    .badge(badge(screen))
                    .tag(screen)
                    .accessibilityIdentifier("nav.\(screen.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                if model.scanning {
                    HStack(spacing: 8) {
                        Peep(mood: .talk, size: 28)
                        Text("Scanning… \(model.projects.count) projects").font(.caption).foregroundStyle(Brand.muted)
                    }
                    .padding(10)
                }
            }
        } detail: {
            ZStack {
                Brand.canvas.ignoresSafeArea()
                Group {
                    switch model.screen {
                    case .overview: OverviewView()
                    case .projects: ProjectsView()
                    case .caches: CachesView()
                    case .history: HistoryView()
                    case .devStack: DevStackView()
                    }
                }
                .id(model.screen)
                .transition(.page(reduce: reduce))
            }
            .animation(.smooth(duration: 0.3), value: model.screen)
        }
        .tint(Brand.teal)
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckAccess()
            model.scanIfStale()
        }
        .sheet(isPresented: $model.onboarding) { Onboarding() }
        .background {
            // ⌘1–⌘5 switch screens.
            ForEach(Array(AppModel.Screen.allCases.enumerated()), id: \.element) { i, screen in
                Button(screen.title) { model.screen = screen }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                    // .hidden() switches the shortcut off on macOS 15.
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .task {
            await model.loadConfig()
            await model.loadHistory()
            await model.freeExpired()
            model.scanIfStale()
            model.onboarding = !UserDefaults.standard.bool(forKey: "onboarded")
                && !ProcessInfo.processInfo.arguments.contains("-scanRoots")
            #if DEBUG
            await QAWalkthrough.run(model)
            await DemoWalkthrough.run(model)
            #endif
        }
    }

    /// Counts the sidebar shows next to a screen, when there is something to count.
    private func badge(_ screen: AppModel.Screen) -> Int {
        switch screen {
        case .projects: model.projects.count
        case .history: model.runs.count
        default: 0
        }
    }
}
