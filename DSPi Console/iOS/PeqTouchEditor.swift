//
//  PeqTouchEditor.swift
//  DSPi Console (iOS target)
//
//  On-graph PEQ editing with touch: the iOS counterpart of the AppKit
//  `PeqGraphEditorView` (work package A3).  It edits the bands of the channel
//  page's channel through the same `PeqGraphEditorHost` calls (live sends
//  while a finger moves, one commit on release), shares the selection with
//  the band list, and draws the edited channel's curve itself, as the macOS
//  editor does.  Gestures follow the Android port's table
//  (dspi-android docs/PORT-MAP.md, "Touch gestures"):
//
//    tap a dot                  select that band
//    tap empty graph            deselect
//    drag a dot                 frequency and gain (Q for 12 dB cuts,
//                               frequency only for notch, all-pass, 6 dB cuts)
//    pinch                      Q of the selected band (spread = higher Q)
//    double-tap empty graph     add a bell there (Q 1), in the first free band
//    long-press a dot           Bypass / Enable, Delete
//
//  Marquee selection, pulling a band out of the curve, the shape chooser and
//  the value chip are not here yet; the band list below the graph does all of
//  that.
//

#if os(iOS)
import SwiftUI

struct PeqTouchEditor: View {
    let vm: DSPViewModel
    let config: PeqGraphEditorConfig
    @ObservedObject private var selection: PeqGraphSelection

    /// Bands a gesture is changing, ahead of the model (sent live, committed
    /// on release).
    @State private var live: [Int: FilterParams] = [:]
    @State private var dragStart: (band: Int, params: FilterParams)?
    @State private var pinchStart: (band: Int, q: Float)?
    @State private var lastSend = Date.distantPast

    /// Visible dot and its touch target.
    private static let dotSize: CGFloat = 14
    private static let hitSize: CGFloat = 44
    /// Live sends at most this often while a finger moves.
    private static let sendInterval: TimeInterval = 1.0 / 30

    init(vm: DSPViewModel, config: PeqGraphEditorConfig) {
        self.vm = vm
        self.config = config
        _selection = ObservedObject(wrappedValue: vm.peqSelection)
    }

    private var channel: Int? { config.channel }

    private func band(_ i: Int) -> FilterParams {
        live[i] ?? config.bands[i]
    }

    private var curveColor: Color {
        Color(red: Double(config.curveColor.x), green: Double(config.curveColor.y),
              blue: Double(config.curveColor.z))
    }

    var body: some View {
        GeometryReader { proxy in
            let g = PeqGraphGeometry(size: proxy.size, minFreq: config.minFreq, maxFreq: config.maxFreq,
                                     dbTop: config.dbTop, dbBottom: config.dbBottom)
            if channel != nil {
                ZStack(alignment: .topLeading) {
                    curve(in: g)
                    backgroundGestures(in: g)
                    ForEach(dotBands, id: \.self) { i in
                        dot(i, in: g)
                    }
                }
            } else {
                Color.clear.allowsHitTesting(false)
            }
        }
    }

    // MARK: - Curve

    /// The edited channel's response, with live changes: bands plus the
    /// crossover's statics plus the output gain.
    private func curve(in g: PeqGraphGeometry) -> some View {
        let bands = config.flat ? [] : config.bands.indices.map(band) + config.statics
        let offset = Double(config.offsetDB)
        let points: [CGPoint] = (0...200).map { k in
            let x = g.size.width * CGFloat(k) / 200
            let f = g.freq(x)
            let db = Double(DSPMath.responseAt(freq: Float(f), filters: bands)) + offset
            return CGPoint(x: x, y: g.y(min(max(db, config.dbBottom - 6), config.dbTop + 6)))
        }
        return Canvas { context, _ in
            var line = Path()
            line.addLines(points)
            var fill = line
            let zeroY = g.y(0)
            fill.addLine(to: CGPoint(x: g.size.width, y: zeroY))
            fill.addLine(to: CGPoint(x: 0, y: zeroY))
            fill.closeSubpath()
            context.fill(fill, with: .color(curveColor.opacity(0.12)))
            if config.glow {
                context.stroke(line, with: .color(curveColor.opacity(0.35)),
                               lineWidth: CGFloat(config.lineWidth) + 4)
            }
            context.stroke(line, with: .color(curveColor), lineWidth: CGFloat(config.lineWidth))
        }
        .allowsHitTesting(false)
    }

    // MARK: - Dots

    private var dotBands: [Int] {
        config.bands.indices.filter { config.bands[$0].isGraphBand }
    }

    private func dotPoint(_ i: Int, in g: PeqGraphGeometry) -> CGPoint {
        let p = band(i)
        let db = PeqNodeRole.of(p).db(for: p) + Double(config.offsetDB)
        return CGPoint(x: g.x(Double(p.freq)), y: g.y(min(max(db, config.dbBottom), config.dbTop)))
    }

    private func dot(_ i: Int, in g: PeqGraphGeometry) -> some View {
        let p = band(i)
        let selected = selection.selected.contains(i)
        let color = PeqBandPalette.color(i)
        return ZStack {
            Circle()
                .fill(p.bypass ? Color.clear : color)
                .overlay(Circle().stroke(color, lineWidth: p.bypass ? 1.5 : 0))
                .frame(width: Self.dotSize, height: Self.dotSize)
            if selected {
                Circle().stroke(Color.white, lineWidth: 2)
                    .frame(width: Self.dotSize + 8, height: Self.dotSize + 8)
            }
        }
        .frame(width: Self.hitSize, height: Self.hitSize)
        .contentShape(Rectangle())
        .position(dotPoint(i, in: g))
        .onTapGesture { selection.selected = [i] }
        .gesture(dotDrag(i, in: g))
        .contextMenu { dotMenu(i) }
        .accessibilityElement()
        .accessibilityLabel("Band \(i + 1), \(p.type.name), \(PeqValueText.frequency(Double(p.freq)))")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func dotMenu(_ i: Int) -> some View {
        let p = band(i)
        if config.bypassSupported, let ch = channel {
            Button(p.bypass ? "Enable" : "Bypass") {
                vm.setGraphBandBypass(ch: ch, band: i, bypass: !p.bypass)
            }
        }
        Button("Delete", role: .destructive) {
            guard let ch = channel else { return }
            var off = p
            off.type = .flat
            off.bypass = false
            vm.commitGraphBands(ch: ch, [(band: i, params: off)])
            selection.selected.remove(i)
        }
    }

    // MARK: - Gestures

    private func dotDrag(_ i: Int, in g: PeqGraphGeometry) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                guard let ch = channel else { return }
                if dragStart?.band != i {
                    dragStart = (i, config.bands[i])
                    selection.selected = [i]
                }
                guard let start = dragStart?.params else { return }
                let p = Self.dragged(start, by: value.translation, in: g)
                live[i] = p
                vm.peqLive.show(band: i, p)
                sendLive(ch: ch, [(band: i, params: p)])
            }
            .onEnded { _ in
                guard let ch = channel, let p = live[i] else { dragStart = nil; return }
                vm.commitGraphBands(ch: ch, [(band: i, params: p)])
                finish()
            }
    }

    /// A band moved by a finger, by its role: a bell or shelf follows with
    /// frequency and gain, a 12 dB cut with frequency and Q, a notch,
    /// all-pass or 6 dB cut with frequency only.
    static func dragged(_ start: FilterParams, by t: CGSize, in g: PeqGraphGeometry) -> FilterParams {
        var p = start
        let role = PeqNodeRole.of(start)
        if case .locked = role { return start }
        let x = g.x(Double(start.freq)) + t.width
        p.freq = Float(PeqLimits.clamp(g.freq(x), PeqLimits.freq))
        let db = role.db(for: start) - Double(t.height) * g.dbPerPoint
        switch role {
        case .gain(let scale):
            p.gain = Float(PeqLimits.clamp(db / scale, PeqLimits.gain))
        case .resonance:
            p.q = Float(PeqLimits.clamp(pow(10, db / 20), PeqLimits.q))
        case .fixed, .locked:
            break
        }
        return p
    }

    /// Taps, double-taps and pinches anywhere that is not a dot.
    private func backgroundGestures(in g: PeqGraphGeometry) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in addBell(at: value.location, in: g) }
                    .exclusively(before: TapGesture().onEnded { selection.selected = [] })
            )
            .simultaneousGesture(pinch)
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let ch = channel else { return }
                if pinchStart == nil {
                    guard selection.selected.count == 1, let i = selection.selected.first,
                          config.bands[i].type.usesQ else { return }
                    pinchStart = (i, config.bands[i].q)
                }
                guard let start = pinchStart else { return }
                var p = config.bands[start.band]
                p.q = Float(PeqLimits.clamp(Double(start.q) * Double(value.magnification), PeqLimits.q))
                live[start.band] = p
                vm.peqLive.show(band: start.band, p)
                sendLive(ch: ch, [(band: start.band, params: p)])
            }
            .onEnded { _ in
                if let ch = channel, let start = pinchStart, let p = live[start.band] {
                    vm.commitGraphBands(ch: ch, [(band: start.band, params: p)])
                }
                finish()
            }
    }

    /// A bell at the finger, in the first band that is off.
    private func addBell(at point: CGPoint, in g: PeqGraphGeometry) {
        guard let ch = channel,
              let free = config.bands.indices.first(where: { config.bands[$0].type == .flat }) else { return }
        var adjusted = point
        adjusted.y = g.y(g.db(point.y) - Double(config.offsetDB))
        let p = PeqCreation.band(at: adjusted, in: g, available: Set(config.availableTypes), fromCurve: false)
        vm.commitGraphBands(ch: ch, [(band: free, params: p)])
        selection.selected = [free]
    }

    private func sendLive(ch: Int, _ changes: [(band: Int, params: FilterParams)]) {
        let now = Date()
        guard now.timeIntervalSince(lastSend) >= Self.sendInterval else { return }
        lastSend = now
        vm.sendGraphBandsToDevice(ch: ch, changes)
    }

    private func finish() {
        dragStart = nil
        pinchStart = nil
        vm.peqLive.endAll()
        // Keep the live values until the model publishes the commit, so the
        // dot does not jump back for a frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { live.removeAll() }
    }
}
#endif
