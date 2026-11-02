// Dandelion - the sunburst chart.
// Each ring is one level deeper; each slice's angle is its share of the folder in the middle.
// The slices and their shapes are worked out once per folder (and window size) and reused for every
// frame, so hovering and animating only repaints.
// MIT License. See LICENSE.

import AppKit
import SwiftUI

struct Slice {
    let node: Node
    let depth: Int
    let a0: Double
    let a1: Double
    /// A grey slice standing for many items too small to draw (node is their folder).
    let isSmallGroup: Bool
    let bytes: Int64
    let count: Int
    let hue: Double
}

enum SunburstLayout {
    static let rings = 6

    static func make(_ focus: Node) -> [Slice] {
        var out: [Slice] = []
        out.reserveCapacity(1500)
        func walk(_ n: Node, _ depth: Int, _ start: Double, _ span: Double) {
            guard depth <= rings, n.size > 0 else { return }
            let minSpan = 0.005 + 0.0012 * Double(depth)   // anything thinner gets grouped
            var a = start
            var rest: Int64 = 0
            var restCount = 0
            let total = Double(n.size)
            for (i, c) in n.children.enumerated() {
                let s = span * Double(c.size) / total
                if s < minSpan {
                    // children are biggest first, so everything from here on is small too
                    for k in i..<n.children.count { rest += n.children[k].size }
                    restCount = n.children.count - i
                    break
                }
                out.append(Slice(node: c, depth: depth, a0: a, a1: a + s, isSmallGroup: false,
                                 bytes: c.size, count: 1, hue: (a + s / 2) / (2 * Double.pi)))
                if c.isDir && !c.children.isEmpty { walk(c, depth + 1, a, s) }
                a += s
            }
            if rest > 0 && restCount > 0 {
                let s = span * Double(rest) / total
                if s > 0.0015 {
                    out.append(Slice(node: n, depth: depth, a0: a, a1: a + s, isSmallGroup: true,
                                     bytes: rest, count: restCount, hue: 0))
                }
            }
        }
        walk(focus, 1, 0, 2 * Double.pi)
        return out
    }

    static func color(_ s: Slice, lit: Bool, dark: Bool) -> Color {
        if s.isSmallGroup { return Color(white: lit ? 0.72 : 0.6, opacity: lit ? 0.75 : 0.42) }
        if s.node.isSynthetic { return Color(white: lit ? 0.64 : 0.5, opacity: 0.85) }
        let d = Double(s.depth - 1)
        var sat = s.node.isDir ? max(0.28, 0.74 - d * 0.08) : 0.2
        var bri = min(1.0, (s.node.isDir ? 0.84 : 0.8) + d * 0.03) - (dark ? 0.06 : 0)
        if lit { sat *= 0.62; bri = 1.0 }
        return Color(hue: s.hue, saturation: sat, brightness: bri)
    }
}

/// Where everything sits for a given size.
struct ChartGeometry: Equatable {
    let center: CGPoint
    let inner: CGFloat
    let ring: CGFloat

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = max(60, min(size.width, size.height) / 2 - 14)
        inner = r * 0.25
        ring = (r - inner) / CGFloat(SunburstLayout.rings)
    }

    func radii(_ depth: Int) -> (CGFloat, CGFloat) {
        (inner + ring * CGFloat(depth - 1) + 1.5, inner + ring * CGFloat(depth))
    }

    func path(_ s: Slice, extra: CGFloat = 0) -> Path {
        let (ri, ro) = radii(s.depth)
        var p = Path()
        let start = Angle.radians(s.a0 - Double.pi / 2)
        let end = Angle.radians(s.a1 - Double.pi / 2)
        p.addArc(center: center, radius: ro + extra, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: center, radius: ri, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// Slices, shapes and lookup tables for the folder on screen. A reference type on purpose:
/// updating it never triggers a redraw by itself.
final class ChartCache {
    private(set) var slices: [Slice] = []
    /// Slice indexes for each ring, in angle order (for a binary-search hit test).
    private(set) var rings: [[Int]] = Array(repeating: [], count: SunburstLayout.rings + 1)
    private var paths: [Path] = []
    private var pathGeometry: ChartGeometry?
    private weak var focus: Node?
    private var version = -1

    func update(_ focus: Node, version: Int) {
        if focus === self.focus && version == self.version { return }
        self.focus = focus
        self.version = version
        slices = SunburstLayout.make(focus)
        rings = Array(repeating: [], count: SunburstLayout.rings + 1)
        for (i, s) in slices.enumerated() { rings[s.depth].append(i) }
        pathGeometry = nil
    }

    func shapes(_ g: ChartGeometry) -> [Path] {
        if pathGeometry != g {
            paths = slices.map { g.path($0) }
            pathGeometry = g
        }
        return paths
    }

    enum Hit: Equatable { case center, slice(Int), nothing }

    func hit(_ p: CGPoint, _ g: ChartGeometry) -> Hit {
        let dx = Double(p.x - g.center.x), dy = Double(p.y - g.center.y)
        let r = (dx * dx + dy * dy).squareRoot()
        if r <= Double(g.inner) { return .center }
        let depth = Int((r - Double(g.inner)) / Double(g.ring)) + 1
        guard depth >= 1, depth <= SunburstLayout.rings else { return .nothing }
        var a = atan2(dx, -dy)   // 0 at the top, clockwise
        if a < 0 { a += 2 * Double.pi }
        let ring = rings[depth]
        var lo = 0, hi = ring.count - 1, found = -1
        while lo <= hi {   // last slice that starts at or before the angle
            let mid = (lo + hi) / 2
            if slices[ring[mid]].a0 <= a { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        if found >= 0, a < slices[ring[found]].a1 { return .slice(ring[found]) }
        return .nothing
    }
}

struct SunburstView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var hover: HoverModel
    @Environment(\.colorScheme) private var scheme
    let focus: Node
    let version: Int

    init(focus: Node, version: Int) {
        self.focus = focus
        self.version = version
    }

    private enum Motion { case reveal, zoomIn, zoomOut, refresh }

    // View state is stored with State(...) directly instead of the @State attribute: in the macOS 26 SDK
    // @State is a macro, and the Command Line Tools don't ship the plugin that expands it.
    private var cacheStore = State(initialValue: ChartCache())
    private var hoverIndexStore = State(initialValue: Int?.none)
    private var hoverCenterStore = State(initialValue: false)
    private var motionStore = State(initialValue: Motion.reveal)
    private var motionStartStore = State(initialValue: Date.distantPast)
    private var hoverStartStore = State(initialValue: Date.distantPast)
    private var lastHoverStore = State(initialValue: Int?.none)
    private var animatingStore = State(initialValue: false)
    private var animUntilStore = State(initialValue: Date.distantPast)

    private var cache: ChartCache { cacheStore.wrappedValue }
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
                TimelineView(.animation(minimumInterval: nil, paused: !animatingStore.wrappedValue)) { tl in
                    Canvas { ctx, size in
                        draw(ctx, ChartGeometry(size: size), now: tl.date)
                    }
                }
                centerLabel(g)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverAt(p, g)
                case .ended: clearHover()
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { p in tap(at: p, g) }
            .onDrag {
                if let n = hover.node, n.canTouch { return NSItemProvider(object: n.url as NSURL) }
                return NSItemProvider()
            }
            .contextMenu {
                if let n = hover.node, !n.isSynthetic {
                    NodeMenu(node: n)
                }
            }
        }
        .onAppear {
            cache.update(focus, version: version)
            animate(.reveal, for: 0.75)
        }
        .onChange(of: focus) { old, new in
            cache.update(new, version: version)
            hoverIndex = nil
            animate(new.parent === old ? .zoomIn : (old.parent === new ? .zoomOut : .refresh), for: 0.55)
        }
        .onChange(of: version) {
            cache.update(focus, version: version)
            hoverIndex = nil
            animate(.refresh, for: 0.35)
        }
        .help("Click a folder to go into it, click the middle to go back up. Drag anything to the bar at the bottom to collect it.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk map of \(focus.title), \(Fmt.bytes(focus.size))")
    }

    // MARK: animation

    private func animate(_ m: Motion, for seconds: Double) {
        if state.reduceMotion { return }
        motionStore.wrappedValue = m
        motionStartStore.wrappedValue = Date()
        keepAnimating(seconds)
    }

    /// Runs the frame clock only while something is moving, so an idle chart costs nothing.
    private func keepAnimating(_ seconds: Double) {
        let until = max(animUntilStore.wrappedValue, Date().addingTimeInterval(seconds))
        animUntilStore.wrappedValue = until
        animatingStore.wrappedValue = true
        let flag = animatingStore
        let deadline = animUntilStore
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) {
            if Date() >= deadline.wrappedValue { flag.wrappedValue = false }
        }
    }

    private static func ease(_ x: Double) -> Double {
        let t = max(0, min(1, x))
        return 1 - pow(1 - t, 3)
    }

    private static func springy(_ x: Double) -> Double {
        let t = max(0, min(1, x))
        return 1 - pow(2, -9 * t) * cos(t * 8)   // overshoots a touch, then settles
    }

    // MARK: drawing

    private func draw(_ base: GraphicsContext, _ g: ChartGeometry, now: Date) {
        cache.update(focus, version: version)
        let slices = cache.slices
        let shapes = cache.shapes(g)
        let dark = scheme == .dark
        let gap = Color(nsColor: .windowBackgroundColor)
        let reduce = state.reduceMotion
        let t = reduce ? 10 : now.timeIntervalSince(motionStartStore.wrappedValue)
        let motion = motionStore.wrappedValue
        let hovered = hover.node
        let selected = state.selected
        let collecting = !state.collector.isEmpty

        var ctx = base
        if motion == .reveal && t < 0.75 {
            // first look: the chart sweeps in clockwise from the top
            let sweep = Self.ease(t / 0.7) * 2 * Double.pi
            var wedge = Path()
            let r = max(g.center.x, g.center.y) * 2
            wedge.move(to: g.center)
            wedge.addArc(center: g.center, radius: r, startAngle: .radians(-Double.pi / 2),
                         endAngle: .radians(sweep - Double.pi / 2), clockwise: false)
            wedge.closeSubpath()
            ctx.clip(to: wedge)
        }

        for depth in 1...SunburstLayout.rings {
            let ring = cache.rings[depth]
            if ring.isEmpty { continue }
            var layer = ctx
            if (motion == .zoomIn || motion == .zoomOut || motion == .refresh) && t < 0.6 {
                // rings bloom outward one after another (zooming out, they settle inward)
                let k = Self.springy((t - Double(depth - 1) * 0.035) / 0.45)
                let from: CGFloat = motion == .zoomIn ? 0.55 : (motion == .zoomOut ? 1.3 : 0.92)
                let scale = from + (1 - from) * CGFloat(k)
                layer.translateBy(x: g.center.x, y: g.center.y)
                layer.scaleBy(x: scale, y: scale)
                layer.translateBy(x: -g.center.x, y: -g.center.y)
                layer.opacity = min(1, max(0, Self.ease((t - Double(depth - 1) * 0.035) / 0.3)))
            }
            for i in ring {
                let s = slices[i]
                let lit = i == hoverIndex || (!s.isSmallGroup && (hovered === s.node || selected === s.node))
                var color = SunburstLayout.color(s, lit: lit, dark: dark)
                if collecting && !s.isSmallGroup && state.isCollected(s.node) { color = color.opacity(0.28) }
                layer.fill(shapes[i], with: .color(color))
                if s.a1 - s.a0 > 0.012 { layer.stroke(shapes[i], with: .color(gap), lineWidth: 1) }
            }
        }

        // the slice under the pointer lifts out a little (and the last one sinks back)
        let ht = reduce ? 10 : now.timeIntervalSince(hoverStartStore.wrappedValue)
        if let last = lastHoverStore.wrappedValue, last != hoverIndex, last < slices.count, ht < 0.18 {
            let k = 1 - Self.ease(ht / 0.16)
            if k > 0.02 { ctx.fill(g.path(slices[last], extra: 5 * k), with: .color(SunburstLayout.color(slices[last], lit: false, dark: dark).opacity(0.9))) }
        }
        if let i = hoverIndex, i < slices.count {
            let k = Self.springy(ht / 0.18)
            let s = slices[i]
            let p = g.path(s, extra: 5 * CGFloat(k))
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: .black.opacity(dark ? 0.45 : 0.22), radius: 6, x: 0, y: 2))
                l.fill(p, with: .color(SunburstLayout.color(s, lit: true, dark: dark)))
            }
        }

        let r = g.inner - 2
        let disc = Path(ellipseIn: CGRect(x: g.center.x - r, y: g.center.y - r, width: r * 2, height: r * 2))
        base.fill(disc, with: .color(Color.primary.opacity(hoverCenter && focus.parent != nil ? 0.12 : 0.055)))
    }

    @ViewBuilder
    private func centerLabel(_ g: ChartGeometry) -> some View {
        let info = centerInfo()
        VStack(spacing: 3) {
            if hoverCenter, focus.parent != nil {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .transition(.scale.combined(with: .opacity))
            }
            Text(info.title)
                .font(.system(size: max(10, min(13, g.inner * 0.13)), weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(info.size)
                .font(.system(size: max(14, min(26, g.inner * 0.21)), weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(info.detail)
                .font(.system(size: max(9, min(11, g.inner * 0.11))))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .multilineTextAlignment(.center)
        .frame(width: max(70, g.inner * 1.6))
        .animation(state.reduceMotion ? nil : .snappy(duration: 0.25), value: info.size)
        .animation(state.reduceMotion ? nil : .snappy(duration: 0.2), value: hoverCenter)
        .position(g.center)
        .allowsHitTesting(false)
    }

    private func centerInfo() -> (title: String, size: String, detail: String) {
        let slices = cache.slices
        if let i = hoverIndex, i < slices.count {
            let s = slices[i]
            if s.isSmallGroup {
                return ("\(Fmt.count(s.count)) smaller items", Fmt.bytes(s.bytes), "Open \(s.node.title) to see them")
            }
            return (s.node.title, Fmt.bytes(s.node.size), state.detail(for: s.node))
        }
        if let h = hover.node, h.parent === focus || h === focus {
            return (h.title, Fmt.bytes(h.size), state.detail(for: h))
        }
        if hoverCenter, let p = focus.parent {
            return ("Back to \(p.title)", Fmt.bytes(p.size), "")
        }
        return (focus.title, Fmt.bytes(focus.size), state.detail(for: focus))
    }

    // MARK: pointer

    private func hoverAt(_ p: CGPoint, _ g: ChartGeometry) {
        switch cache.hit(p, g) {
        case .center:
            if !hoverCenter { hoverCenter = true }
            setHoverIndex(nil)
            hover.set(nil)
        case .slice(let i):
            if hoverCenter { hoverCenter = false }
            setHoverIndex(i)
            let s = cache.slices[i]
            hover.set(s.isSmallGroup ? nil : s.node)
        case .nothing:
            clearHover()
        }
    }

    private func setHoverIndex(_ i: Int?) {
        guard hoverIndex != i else { return }
        lastHoverStore.wrappedValue = hoverIndex
        hoverIndex = i
        hoverStartStore.wrappedValue = Date()
        if !state.reduceMotion { keepAnimating(0.2) }
    }

    private func clearHover() {
        if hoverCenter { hoverCenter = false }
        setHoverIndex(nil)
        hover.set(nil)
    }

    private func tap(at p: CGPoint, _ g: ChartGeometry) {
        switch cache.hit(p, g) {
        case .center:
            state.up()
        case .slice(let i):
            let s = cache.slices[i]
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
