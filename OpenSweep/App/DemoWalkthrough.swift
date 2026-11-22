// SPDX-License-Identifier: MIT
import SwiftUI

extension View {
    /// Lets the Debug demo press this button. A no-op in Release builds.
    func demoPress(_ id: String, perform: @escaping () -> Void) -> some View {
        #if DEBUG
        modifier(DemoPress(id: id, perform: perform))
        #else
        self
        #endif
    }
}

#if DEBUG
import AppKit
import AgentEngine

private struct DemoPress: ViewModifier {
    @Environment(AppModel.self) private var model
    let id: String
    let perform: () -> Void

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { DemoWalkthrough.frames[id] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in DemoWalkthrough.frames[id] = f }
            })
            .onChange(of: model.demoPress) { _, pressed in
                if pressed == id { perform() }
            }
    }
}

/// Debug builds only. With OPENSWEEP_DEMO=<folder>, plays the README demo at
/// a filmable pace: scan, Review all ready, clean, then each screen. It
/// snapshots every step and writes timeline.json (button positions and
/// times) for the video edit. Run it only with scripts/demo/engine.py as
/// OPENSWEEP_BIN; see scripts/demo/record.sh.
@MainActor
enum DemoWalkthrough {
    static var frames: [String: CGRect] = [:]

    static func run(_ model: AppModel) async {
        guard let out = ProcessInfo.processInfo.environment["OPENSWEEP_DEMO"].map(URL.init(fileURLWithPath:)) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        switch ProcessInfo.processInfo.environment["OPENSWEEP_QA_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.title != "Settings" }) else { return }
        main.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: true)
        main.center()
        NSApp.activate(ignoringOtherApps: true)
        main.makeKeyAndOrderFront(nil)
        // The real pointer stays out of the film; the edit draws its own.
        NSCursor.hide()
        await pause(1)

        // Top-left screen coordinates, in points, as screencapture -R takes them.
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let w = main.frame
        let window: [String: Double] = ["x": w.minX, "y": screenH - w.maxY, "w": w.width, "h": w.height,
                                        "scale": main.backingScaleFactor]
        try? JSONSerialization.data(withJSONObject: window).write(to: out.appendingPathComponent("window.json"))
        // record.sh starts the screen recording, then creates "go".
        let go = out.appendingPathComponent("go")
        for _ in 0..<200 where !fm.fileExists(atPath: go.path) { await pause(0.1) }
        let start = Date()
        var timeline: [[String: Any]] = []

        func mark(_ what: String, at id: String? = nil) {
            var e: [String: Any] = ["t": Date().timeIntervalSince(start), "event": what]
            if let id, let f = frames[id],
               let win = NSApp.windows.first(where: { $0.isVisible && $0.isSheet }) ?? Optional(main),
               let view = win.contentView {
                // SwiftUI's global frame is in the window's content view (flipped).
                let p = win.convertPoint(toScreen: view.convert(NSPoint(x: f.midX, y: f.midY), to: nil))
                e["x"] = p.x - main.frame.minX
                e["y"] = main.frame.maxY - p.y
            }
            timeline.append(e)
        }
        func press(_ id: String) async {
            mark("press", at: id)
            await pause(0.35)          // the cursor lands, then the click
            model.demoPress = id
            await pause(0.05)
            model.demoPress = nil
        }
        func snap(_ name: String) {
            mark("snap:" + name)
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let win = NSApp.windows.first(where: { $0.isVisible && $0.isSheet }) ?? Optional(main),
                  let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                  let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(win.windowNumber), 1)?.takeRetainedValue()
            else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: out.appendingPathComponent("\(name).png"))
        }
        func render(_ view: some View, width: CGFloat, _ name: String) {
            // Off screen, colours follow the drawing appearance, not the window's.
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                let r = ImageRenderer(content: view.environment(model).padding(28).frame(width: width).background(Brand.canvas)
                    .environment(\.colorScheme, dark ? .dark : .light))
                r.scale = 2
                if let cg = r.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: out.appendingPathComponent("\(name).png"))
                }
            }
        }

        mark("start")
        await pause(1.5)
        await press("scan")
        await pause(0.8)
        while model.scanning { await pause(0.2) }
        mark("scanned")
        await pause(3)
        snap("overview")
        let stats = LanguageStat.of(model.projects)
        render(SpaceFlow(stats: stats, hovered: .constant(nil), animate: false), width: 1200, "space-flow")
        render(DiskMap(stats: stats), width: 1100, "disk-map")

        // A dormant project with the most ticked for you: why each folder is safe.
        model.screen = .projects
        model.selectedProject = model.projects.filter { $0.verdict == .dormant }
            .max { ($0.items.count, model.total($0)) < ($1.items.count, model.total($1)) }?.root
        mark("projects")
        await pause(3.5)
        snap("projects")
        model.screen = .overview
        mark("overview")
        await pause(1.5)

        await press("reviewAll")
        while !NSApp.windows.contains(where: { $0.isVisible && $0.isSheet }) { await pause(0.1) }
        mark("review")
        await pause(3)
        snap("review")
        await press("confirmClean")
        while frames["done"] == nil { await pause(0.1) }
        mark("cleaned")
        await pause(3)
        snap("cleaned")
        await press("done")
        await pause(1)
        mark("after")
        await pause(3)
        snap("overview-after")

        model.screen = .caches
        await model.loadCaches()
        mark("caches")
        await pause(3.5)
        snap("caches")

        model.screen = .history
        await model.loadHistory()
        mark("history")
        await pause(3.5)
        snap("history")
        mark("end")

        try? JSONSerialization.data(withJSONObject: timeline, options: .prettyPrinted)
            .write(to: out.appendingPathComponent("timeline.json"))
        await pause(0.5)
        NSCursor.unhide()
        NSApp.terminate(nil)
    }
}
#endif
