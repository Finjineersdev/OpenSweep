// SPDX-License-Identifier: MIT
//
// Motion and characters. Every moving piece stops or shortens when
// the person turns on Reduce Motion. The characters are Open Peeps by Pablo
// Stanley (CC0), see docs/THIRD-PARTY.md.

import SwiftUI
import AppKit

/// The one clock behind every endless motion: a single 12 Hz timer, stopped
/// while the app is in the background or Reduce Motion is on. Only views that
/// read `t` redraw on a tick. SwiftUI's `repeatForever` animations and
/// `TimelineView(.animation)` both kept the display loop at full rate
/// instead (measured: about 30% of a core while idle).
@MainActor @Observable
final class AmbientClock {
    static let shared = AmbientClock()
    private(set) var t: Double = 0
    @ObservationIgnored private var timer: Timer?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AmbientClock.shared.update() }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AmbientClock.shared.update() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AmbientClock.shared.update() }
        }
        update()
    }

    private func update() {
        let run = (NSApp?.isActive ?? true) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if run, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 12, repeats: true) { _ in
                MainActor.assumeIsolated { AmbientClock.shared.t = Date.timeIntervalSinceReferenceDate }
            }
        } else if !run {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// Hands `content` the ambient clock's time.
struct Ambient<Content: View>: View {
    @ViewBuilder let content: (Double) -> Content
    var body: some View { content(AmbientClock.shared.t) }
}

// MARK: - Entrances

/// Fades and lifts a view the first time it appears; `delay` staggers lists.
struct Entrance: ViewModifier {
    let delay: Double
    let edge: Edge
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        let still = shown || reduce
        content
            .opacity(shown ? 1 : 0)
            .offset(x: still ? 0 : (edge == .leading ? -12 : edge == .trailing ? 12 : 0),
                    y: still ? 0 : (edge == .bottom ? 10 : edge == .top ? -10 : 0))
            .onAppear {
                withAnimation(reduce ? .easeOut(duration: 0.2) : .smooth(duration: 0.45).delay(delay)) { shown = true }
            }
    }
}

extension View {
    /// Item `index` of a list enters a little after the one before it.
    func entrance(_ index: Int = 0, from edge: Edge = .bottom) -> some View {
        modifier(Entrance(delay: min(Double(index) * 0.04, 0.32), edge: edge))
    }

    func hoverLift(_ tint: Color, radius: CGFloat = 18) -> some View { modifier(HoverLift(tint: tint, radius: radius)) }
}

/// How a whole screen arrives when the sidebar changes it.
struct PageShift: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.opacity(on ? 0 : 1).offset(y: on ? 8 : 0)
    }
}

extension AnyTransition {
    static func page(reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .modifier(active: PageShift(on: true), identity: PageShift(on: false)),
                                        removal: .opacity.animation(.easeOut(duration: 0.12)))
    }
}

// MARK: - Hover

/// Lifts a card a couple of points and edges it in its own colour.
struct HoverLift: ViewModifier {
    let tint: Color
    let radius: CGFloat
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(tint.opacity(hover ? 0.55 : 0), lineWidth: 1).allowsHitTesting(false))
            .offset(y: hover && !reduce ? -2 : 0)
            .shadow(color: .black.opacity(hover ? 0.18 : 0), radius: 16, y: 8)
            .animation(.smooth(duration: 0.22), value: hover)
            .onHover { hover = $0 }
    }
}

/// A soft lumpy shape behind a character.
struct Blob: Shape {
    var seed: Double = 1
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let n = 90
        for i in 0...n {
            let a = Double(i) / Double(n) * .pi * 2
            let k = 1 + 0.06 * sin(a * 3 + seed) + 0.04 * cos(a * 5 + seed * 2)
            let q = CGPoint(x: c.x + r.width / 2 * k * 0.94 * cos(a), y: c.y + r.height / 2 * k * 0.94 * sin(a))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Characters

/// One of the Open Peeps cast on a lumpy coloured blob. Still at rest; the
/// face swaps with a small spring when the mood changes.
struct Peep: View {
    /// Settings switch for the character and the cleaning stats (F19).
    static let showKey = "showCharacter"
    enum Mood: String { case happy, talk, calm, wow, lol }
    let asset: String
    var size: CGFloat = 96
    var backdrop: Color = Brand.teal
    var phase: Double = 0

    init(mood: Mood, size: CGFloat = 96, backdrop: Color = Brand.teal) {
        asset = "peep-host-\(mood.rawValue)"; self.size = size; self.backdrop = backdrop
    }

    init(crew: Int, size: CGFloat = 64, backdrop: Color = Brand.teal, phase: Double = 0) {
        asset = "peep-crew-\(crew)"; self.size = size; self.backdrop = backdrop; self.phase = phase
    }

    @AppStorage(Peep.showKey) private var show = true

    var body: some View {
        if show { shown }
    }

    private var shown: some View {
        figure
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: asset)
        .accessibilityHidden(true)
    }

    private var figure: some View {
        ZStack {
            Blob(seed: phase + 1).fill(backdrop)
            Image(asset).resizable().scaledToFit()
                .padding(size * 0.04)
                .clipShape(Circle())
                .id(asset)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .frame(width: size, height: size)
    }
}

/// What the host says, typed out a letter at a time.
struct SpeechBubble: View {
    let text: String
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(text).opacity(0)
            Text(String(text.prefix(shown)))
        }
        .font(.title3.weight(.medium))
        .foregroundStyle(Brand.text)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.raised)
                RoundedRectangle(cornerRadius: 4).fill(Brand.raised).frame(width: 16, height: 16)
                    .rotationEffect(.degrees(45)).offset(x: -6)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isStaticText)
        .task(id: text) {
            if reduce { shown = text.count; return }
            shown = 0
            for i in 0...text.count {
                shown = i
                try? await Task.sleep(for: .milliseconds(14))
            }
        }
    }
}
