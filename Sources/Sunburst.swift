// Dandelion - the sunburst chart.
// Each ring is one level deeper; each slice's angle is its share of the folder in the middle.
// MIT License. See LICENSE.

import AppKit
import SwiftUI

struct Slice {
    let node: Node
    let depth: Int
    let a0: Double
    let a1: Double
    /// A grey slice that stands for many items too small to draw (node is their folder).
    let isSmallGroup: Bool
    let bytes: Int64
    let hue: Double
}

enum SunburstLayout {
    static let rings = 6

    static func make(_ focus: Node) -> [Slice] {
        var out: [Slice] = []
        out.reserveCapacity(1500)
        func walk(_ n: Node, _ depth: Int, _ start: Double, _ span: Double) {
            guard depth <= rings, n.size > 0 else { return }
            let minSpan = 0.005 + 0.0012 * Double(depth)   // smaller than this gets grouped
            var a = start
            var rest: Int64 = 0
            var restCount = 0
            for (i, c) in n.children.enumerated() {
                let s = span * Double(c.size) / Double(n.size)
                if s < minSpan {
                    // children are biggest first, so everything from here on is small too
                    for k in i..<n.children.count { rest += n.children[k].size }
                    restCount = n.children.count - i
                    break
                }
                out.append(Slice(node: c, depth: depth, a0: a, a1: a + s, isSmallGroup: false,
                                 bytes: c.size, hue: (a + s / 2) / (2 * Double.pi)))
                if c.isDir && !c.children.isEmpty { walk(c, depth + 1, a, s) }
                a += s
            }
            if rest > 0 && restCount > 0 {
                let s = span * Double(rest) / Double(n.size)
                if s > 0.0015 {
                    out.append(Slice(node: n, depth: depth, a0: a, a1: a + s, isSmallGroup: true,
                                     bytes: rest, hue: 0))
                }
            }
        }
        walk(focus, 1, 0, 2 * Double.pi)
        return out
    }

    static func color(_ s: Slice, lit: Bool) -> Color {
        if s.isSmallGroup { return Color(white: lit ? 0.72 : 0.6, opacity: lit ? 0.75 : 0.45) }
        if s.node.isSynthetic { return Color(white: lit ? 0.62 : 0.5, opacity: 0.85) }
        let d = Double(s.depth - 1)
        var sat = s.node.isDir ? max(0.28, 0.74 - d * 0.08) : 0.2
        var bri = min(1.0, (s.node.isDir ? 0.84 : 0.8) + d * 0.03)
        if lit { sat *= 0.65; bri = 1.0 }
        return Color(hue: s.hue, saturation: sat, brightness: bri)
    }
}

/// Where everything sits for a given size.
struct ChartGeometry {
    let center: CGPoint
    let inner: CGFloat
    let ring: CGFloat

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = max(60, min(size.width, size.height) / 2 - 12)
        inner = r * 0.25
        ring = (r - inner) / CGFloat(SunburstLayout.rings)
    }

    func radii(_ depth: Int) -> (CGFloat, CGFloat) {
        (inner + ring * CGFloat(depth - 1) + 1.5, inner + ring * CGFloat(depth))
    }

    enum Hit { case center, slice(Int), nothing }

    func hit(_ p: CGPoint, slices: [Slice]) -> Hit {
        let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
        let r = (dx * dx + dy * dy).squareRoot()
        if r <= Double(inner) { return .center }
        let depth = Int((r - Double(inner)) / Double(ring)) + 1
        if depth > SunburstLayout.rings { return .nothing }
        var a = atan2(dx, -dy)   // 0 at the top, clockwise
        if a < 0 { a += 2 * Double.pi }
        if let i = slices.firstIndex(where: { $0.depth == depth && a >= $0.a0 && a < $0.a1 }) { return .slice(i) }
        return .nothing
    }
}

struct SunburstView: View {
    @EnvironmentObject var state: AppState
    let focus: Node
    let version: Int

    init(focus: Node, version: Int) {
        self.focus = focus
        self.version = version
    }

    // View state is stored with State(...) directly instead of the @State attribute: in the macOS 26 SDK
    // @State is a macro, and the Command Line Tools don't ship the plugin that expands it.
    private var sliceStore = State(initialValue: [Slice]())
    private var hoverIndexStore = State(initialValue: Int?.none)
    private var hoverCenterStore = State(initialValue: false)
    private var slices: [Slice] {
        get { sliceStore.wrappedValue }
        nonmutating set { sliceStore.wrappedValue = newValue }
    }
    private var hoverIndex: Int? {
        get { hoverIndexStore.wrappedValue }
        nonmutating set { hoverIndexStore.wrappedValue = newValue }
    }
    private var hoverCenter: Bool {
        get { hoverCenterStore.wrappedValue }
        nonmutating set { hoverCenterStore.wrappedValue = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let g = ChartGeometry(size: geo.size)
            ZStack {
                Canvas { ctx, size in
                    draw(ctx, ChartGeometry(size: size))
                }
                centerLabel(g)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover(at: p, g)
                case .ended: clearHover()
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { p in tap(at: p, g) }
            .onDrag {
                if let n = state.hovered, n.canTouch { return NSItemProvider(object: n.url as NSURL) }
                return NSItemProvider()
            }
            .contextMenu {
                if let n = state.hovered, !n.isSynthetic {
                    NodeMenu(node: n)
                }
            }
        }
        .onAppear { relayout() }
        .onChange(of: focus) { relayout() }
        .onChange(of: version) { relayout() }
        .help(helpText)
    }

    private var helpText: String {
        "Click a folder to go into it, click the middle to go back up. Drag anything to the bar at the bottom to collect it."
    }

    private func relayout() {
        slices = SunburstLayout.make(focus)
        hoverIndex = nil
    }

    private func draw(_ ctx: GraphicsContext, _ g: ChartGeometry) {
        let gap = Color(nsColor: .windowBackgroundColor)
        for (i, s) in slices.enumerated() {
            let (ri, ro) = g.radii(s.depth)
            var path = Path()
            let start = Angle.radians(s.a0 - Double.pi / 2)
            let end = Angle.radians(s.a1 - Double.pi / 2)
            path.addArc(center: g.center, radius: ro, startAngle: start, endAngle: end, clockwise: false)
            path.addArc(center: g.center, radius: ri, startAngle: end, endAngle: start, clockwise: true)
            path.closeSubpath()
            let lit = i == hoverIndex || (!s.isSmallGroup && state.hovered === s.node) || (!s.isSmallGroup && state.selected === s.node)
            let collected = !s.isSmallGroup && state.isCollected(s.node)
            ctx.fill(path, with: .color(SunburstLayout.color(s, lit: lit).opacity(collected ? 0.35 : 1)))
            if s.a1 - s.a0 > 0.012 { ctx.stroke(path, with: .color(gap), lineWidth: 1) }
        }
        let r = g.inner - 2
        let disc = Path(ellipseIn: CGRect(x: g.center.x - r, y: g.center.y - r, width: r * 2, height: r * 2))
        ctx.fill(disc, with: .color(Color.primary.opacity(hoverCenter && focus.parent != nil ? 0.12 : 0.06)))
    }

    @ViewBuilder
    private func centerLabel(_ g: ChartGeometry) -> some View {
        let info = centerInfo()
        VStack(spacing: 3) {
            if hoverCenter, focus.parent != nil {
                Image(systemName: "arrow.up.circle").font(.system(size: 18)).foregroundStyle(.secondary)
            }
            Text(info.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(info.size)
                .font(.system(size: max(14, min(26, g.inner * 0.2)), weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(info.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .multilineTextAlignment(.center)
        .frame(width: max(80, g.inner * 1.6))
        .position(g.center)
        .allowsHitTesting(false)
    }

    private func centerInfo() -> (title: String, size: String, detail: String) {
        if let i = hoverIndex, i < slices.count {
            let s = slices[i]
            if s.isSmallGroup {
                return ("Smaller items", Fmt.bytes(s.bytes), "Too small to show here. Open \(s.node.title) to see them.")
            }
            return (s.node.title, Fmt.bytes(s.node.size), state.detail(for: s.node))
        }
        if let h = state.hovered, h.parent === focus || h === focus {
            return (h.title, Fmt.bytes(h.size), state.detail(for: h))
        }
        if hoverCenter, let p = focus.parent {
            return ("Back to \(p.title)", Fmt.bytes(p.size), "")
        }
        return (focus.title, Fmt.bytes(focus.size), state.detail(for: focus))
    }

    private func hover(at p: CGPoint, _ g: ChartGeometry) {
        switch g.hit(p, slices: slices) {
        case .center:
            if !hoverCenter { hoverCenter = true }
            if hoverIndex != nil { hoverIndex = nil }
            if state.hovered != nil { state.hovered = nil }
        case .slice(let i):
            if hoverCenter { hoverCenter = false }
            if hoverIndex != i { hoverIndex = i }
            let n: Node? = slices[i].isSmallGroup ? nil : slices[i].node
            if state.hovered !== n { state.hovered = n }
        case .nothing:
            clearHover()
        }
    }

    private func clearHover() {
        if hoverCenter { hoverCenter = false }
        if hoverIndex != nil { hoverIndex = nil }
        if state.hovered != nil { state.hovered = nil }
    }

    private func tap(at p: CGPoint, _ g: ChartGeometry) {
        switch g.hit(p, slices: slices) {
        case .center:
            state.up()
        case .slice(let i):
            let s = slices[i]
            if s.isSmallGroup {
                if s.node !== focus { state.zoom(into: s.node) }
            } else if s.node.isDir && !s.node.isSynthetic {
                state.zoom(into: s.node)
            } else {
                state.selected = s.node
            }
        case .nothing:
            state.selected = nil
        }
    }
}

/// The right-click menu for an item (used by the chart and the list).
struct NodeMenu: View {
    @EnvironmentObject var state: AppState
    let node: Node

    var body: some View {
        if node.isDir {
            Button("Open Folder Here") { state.zoom(into: node) }
        }
        Button("Reveal in Finder") { state.reveal(node) }
        Button("Quick Look") { state.quickLook(node) }
        Button("Open") { state.open(node) }
        Button("Copy Path") { state.copyPath(node) }
        if node.canTouch {
            Divider()
            if state.isCollected(node) {
                Button("Remove from Collector") { state.uncollect(node) }
            } else {
                Button("Add to Collector") { state.collect(node) }
            }
        }
    }
}
