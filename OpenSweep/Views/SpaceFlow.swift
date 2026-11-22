// SPDX-License-Identifier: MIT

import SwiftUI

/// Where the space goes: each language on the left flows into what can be
/// done with it on the right (ready now, needs a reinstall, in use). Band
/// thickness is bytes. Hovering a language highlights its flows and the ring.
struct SpaceFlow: View {
    let stats: [LanguageStat]
    @Binding var hovered: String?
    /// Draw the bands in from the left on first appearance.
    var animate = true
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    private struct Node: Identifiable {
        let id: String
        let name: String
        let value: Double
        let color: Color
        var ecosystem: Ecosystem?
    }

    private static let shown = 6
    private static let minHeight: CGFloat = 12
    private static let gap: CGFloat = 12
    private static let bar: CGFloat = 8

    /// The biggest languages, the rest folded into "Other".
    private var sources: [LanguageStat] {
        let sorted = stats.sorted { $0.total > $1.total }
        guard sorted.count > Self.shown else { return sorted }
        var other = LanguageStat(ecosystem: Ecosystem(id: "other", name: "Other", logo: nil, color: Brand.slate, symbol: "ellipsis"))
        for s in sorted.dropFirst(Self.shown - 1) {
            other.ready += s.ready; other.caution += s.caution; other.active += s.active
        }
        return Array(sorted.prefix(Self.shown - 1)) + [other]
    }

    private static let buckets: [(id: String, name: String, color: Color, value: (LanguageStat) -> UInt64)] = [
        ("ready", "Ready to clean", Brand.green, { $0.ready }),
        ("caution", "Needs a reinstall", Brand.amber, { $0.caution }),
        ("active", "In active projects", Brand.sky, { $0.active }),
    ]

    var body: some View {
        let src = sources
        let left = src.map { Node(id: $0.id, name: $0.ecosystem.name, value: Double($0.total), color: $0.ecosystem.color, ecosystem: $0.ecosystem) }
        let right = Self.buckets.map { b in
            Node(id: b.id, name: b.name, value: Double(src.reduce(0) { $0 + b.value($1) }), color: b.color)
        }.filter { $0.value > 0 }
        let total = max(left.reduce(0) { $0 + $1.value }, 1)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where the space goes").font(.title2.bold()).foregroundStyle(Brand.text).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(bytes(UInt64(total))) found, by language and what can be done with it")
                    .font(.callout).foregroundStyle(Brand.muted).lineLimit(1)
            }
            GeometryReader { g in
                let labelL: CGFloat = 190, labelR: CGFloat = 210
                let x0 = labelL, x1 = g.size.width - labelR
                let l = layout(left, total: total, height: g.size.height)
                let r = layout(right, total: total, height: g.size.height)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        var lOff = l.map { $0.minY + Self.minHeight / 2 }, rOff = r.map { $0.minY + Self.minHeight / 2 }
                        let k = scale(left.count, total: total, height: g.size.height)
                        for (i, s) in src.enumerated() {
                            for (j, node) in right.enumerated() {
                                guard let b = Self.buckets.first(where: { $0.id == node.id }) else { continue }
                                let v = Double(b.value(s))
                                guard v > 0 else { continue }
                                let t = max(CGFloat(v) * k, 1.5)
                                let a = CGRect(x: x0 + Self.bar, y: lOff[i], width: 0, height: t)
                                let z = CGRect(x: x1 - Self.bar, y: rOff[j], width: 0, height: t)
                                lOff[i] += t; rOff[j] += t
                                let on = hovered == nil || hovered == s.id
                                ctx.fill(ribbon(from: a, to: z), with: .linearGradient(
                                    Gradient(colors: [left[i].color.opacity(on ? 0.55 : 0.12), node.color.opacity(on ? 0.45 : 0.10)]),
                                    startPoint: CGPoint(x: a.minX, y: 0), endPoint: CGPoint(x: z.minX, y: 0)))
                            }
                        }
                        for (i, rect) in l.enumerated() {
                            ctx.fill(Path(roundedRect: CGRect(x: x0, y: rect.minY, width: Self.bar, height: rect.height), cornerRadius: 3), with: .color(left[i].color))
                        }
                        for (j, rect) in r.enumerated() {
                            ctx.fill(Path(roundedRect: CGRect(x: x1 - Self.bar, y: rect.minY, width: Self.bar, height: rect.height), cornerRadius: 3), with: .color(right[j].color))
                        }
                    }
                    .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * (animate ? drawn : 1)) }
                    .accessibilityHidden(true)

                    ForEach(Array(left.enumerated()), id: \.element.id) { i, n in
                        HStack(spacing: 8) {
                            if let e = n.ecosystem { EcosystemBadge(ecosystem: e, size: 22) }
                            Text(n.name).font(.callout.weight(.semibold)).foregroundStyle(Brand.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(bytes(UInt64(n.value))).font(.callout).monospacedDigit().foregroundStyle(Brand.muted)
                        }
                        .padding(.trailing, 10)
                        .frame(width: labelL, height: 24)
                        .contentShape(Rectangle())
                        .position(x: labelL / 2, y: l[i].midY)
                        .opacity(hovered == nil || hovered == n.id ? 1 : 0.45)
                        .onHover { hovered = $0 ? n.id : (hovered == n.id ? nil : hovered) }
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(Array(right.enumerated()), id: \.element.id) { j, n in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(n.name).font(.callout.weight(.semibold)).foregroundStyle(Brand.text)
                            Text("\(bytes(UInt64(n.value))) · \(percent(n.value / total))")
                                .font(.caption).monospacedDigit().foregroundStyle(n.color)
                        }
                        .padding(.leading, 12)
                        .frame(width: labelR, alignment: .leading)
                        .position(x: x1 + labelR / 2, y: r[j].midY)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(height: max(220, CGFloat(left.count) * 40))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Where the space goes")
            .animation(.smooth(duration: 0.25), value: hovered)
        }
        .padding(24)
        .glassCard(radius: 20)
        .onAppear {
            if reduce || !animate { drawn = 1 } else { withAnimation(.smooth(duration: 0.9).delay(0.15)) { drawn = 1 } }
        }
    }

    private func percent(_ share: Double) -> String {
        share > 0 && share < 0.005 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }

    /// Points per byte, after the gaps and each node's minimum height.
    private func scale(_ count: Int, total: Double, height: CGFloat) -> CGFloat {
        max(height - Self.gap * CGFloat(max(count - 1, 0)) - Self.minHeight * CGFloat(count), 0) / CGFloat(total)
    }

    /// Stacked node rectangles (only y and height matter), centred vertically.
    private func layout(_ nodes: [Node], total: Double, height: CGFloat) -> [CGRect] {
        let k = scale(nodes.count, total: total, height: height)
        var y: CGFloat = 0
        var out: [CGRect] = []
        for n in nodes {
            let h = Self.minHeight + CGFloat(n.value) * k
            out.append(CGRect(x: 0, y: y, width: 0, height: h))
            y += h + Self.gap
        }
        let shift = max((height - (y - Self.gap)) / 2, 0)
        return out.map { $0.offsetBy(dx: 0, dy: shift) }
    }

    /// A band from one node edge to another with S-curved sides.
    private func ribbon(from a: CGRect, to z: CGRect) -> Path {
        let mid = (a.minX + z.minX) / 2
        var p = Path()
        p.move(to: CGPoint(x: a.minX, y: a.minY))
        p.addCurve(to: CGPoint(x: z.minX, y: z.minY), control1: CGPoint(x: mid, y: a.minY), control2: CGPoint(x: mid, y: z.minY))
        p.addLine(to: CGPoint(x: z.minX, y: z.maxY))
        p.addCurve(to: CGPoint(x: a.minX, y: a.maxY), control1: CGPoint(x: mid, y: z.maxY), control2: CGPoint(x: mid, y: a.maxY))
        p.closeSubpath()
        return p
    }
}
