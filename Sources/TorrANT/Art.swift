import SwiftUI
import AppKit

// MARK: - The sketched ant (mascot)

enum AntPose { case hero, walk, alert, rest }

/// The hand-drawn mascot from the mockups, drawn natively.
/// Subtle life: antenna twitch, breathing abdomen, bobbing crumb.
struct AntSketch: View {
    var pose: AntPose = .hero
    var guides = false
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let box = CGSize(width: 340, height: 250)

    private struct Legs { let near: [String]; let far: [String] }
    private static let stand = Legs(
        near: ["M200 132 L220 150 L230 194 L240 198", "M184 138 L180 160 L190 196 L198 199", "M166 134 L146 156 L132 196 L122 199"],
        far: ["M206 128 L230 140 L248 186", "M190 134 L198 156 L214 192", "M170 130 L160 150 L152 192"])
    private static let walk = Legs(
        near: ["M200 132 L224 144 L246 188 L254 190", "M184 138 L176 162 L172 198 L164 200", "M166 134 L150 160 L144 198 L136 200"],
        far: ["M206 128 L222 146 L226 192", "M190 134 L204 156 L224 190", "M170 130 L150 146 L118 186"])
    private static let tuck = Legs(
        near: ["M200 132 L216 148 L206 168", "M184 138 L190 156 L176 170", "M166 134 L156 152 L142 166"],
        far: ["M206 128 L222 144 L216 162", "M190 134 L198 152 L188 166", "M170 130 L162 148 L150 160"])

    private var legs: Legs {
        switch pose { case .walk: return Self.walk; case .rest: return Self.tuck; default: return Self.stand }
    }
    private var antennae: (String, String) {
        switch pose {
        case .hero: return ("M236 84 L240 56 L226 34", "M228 84 L222 58 L204 40")
        case .walk: return ("M236 84 L252 64 L288 72", "M228 84 L242 62 L276 60")
        case .alert: return ("M236 84 L246 52 L278 30", "M228 84 L232 50 L260 24")
        case .rest: return ("M236 84 L232 68 L206 64", "M228 84 L222 70 L198 72")
        }
    }
    private var dy: CGFloat { pose == .rest ? 26 : 0 }
    private var live: Bool { animated && !reduceMotion }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / Self.box.width
            ZStack {
                ink("M18 203 C80 200 160 205 240 201 S 320 204 332 202", 1.4, s, op: 0.45, shift: false)
                if guides {
                    ZStack {
                        shape(circle(94, 140 + dy, 42)).stroke(Theme.chalk.opacity(0.16), lineWidth: s)
                        shape(circle(236, 106 + dy, 28)).stroke(Theme.chalk.opacity(0.16), lineWidth: s)
                    }
                }
                // far side: fainter
                ForEach(legs.far, id: \.self) { ink($0, 1.6, s, op: 0.5) }
                twitch(ink(antennae.1, 1.6, s, op: 0.5), anchor: UnitPoint(x: 228 / 340, y: (84 + dy) / 250), late: true)
                // hatching
                hatch("M50 154 C58 174 92 180 116 170 C134 162 144 146 140 128 C126 150 92 162 50 154 Z", s)
                hatch("M216 126 C230 134 252 130 260 118 C250 124 230 126 216 118 Z", s)
                hatch("M160 132 C172 140 192 140 204 130 C192 134 172 134 160 126 Z", s)
                // body
                breathe(ZStack {
                    ink("M140 128 C134 104 104 98 80 104 C54 110 42 134 50 154 C58 174 92 180 116 170 C134 162 144 146 140 128 Z", 2.2, s)
                    ink("M124 108 C112 124 112 150 122 168", 1.4, s)
                    ink("M104 101 C90 122 90 154 102 175", 1.4, s)
                })
                ink("M140 126 C144 116 154 116 156 126 C154 134 144 136 140 126 Z", 2.2, s)
                ink("M156 124 C160 106 190 100 204 110 C214 118 208 134 192 138 C176 142 158 138 156 124 Z", 2.2, s)
                ink("M178 106 C180 116 182 128 186 138", 1.4, s)
                ink("M206 108 C206 88 226 78 244 82 C262 86 268 104 260 118 C252 130 230 134 216 126 C208 122 206 116 206 108 Z", 2.2, s)
                ink("M258 118 C270 120 276 128 268 134 C264 130 260 126 254 126", 2.2, s)
                ink("M252 124 C262 130 264 138 256 140", 1.6, s)
                ForEach(legs.near, id: \.self) { ink($0, 2.2, s) }
                twitch(ink(antennae.0, 2.2, s), anchor: UnitPoint(x: 236 / 340, y: (84 + dy) / 250), late: false)
                shape(ellipse(244, 100 + dy, 6, 5)).fill(Theme.soil)
                shape(ellipse(244, 100 + dy, 6, 5)).stroke(Theme.chalk, lineWidth: 1.8 * s)
                shape(circle(246, 98 + dy, 1.6)).fill(Theme.chalk)

                if pose == .hero { bob(crumb(s)) }
                if pose == .alert {
                    Text("!").font(.custom("Caveat", size: 64 * s).weight(.bold)).foregroundStyle(Theme.honey)
                        .position(x: 298 * s, y: 34 * s)
                }
                if pose == .rest {
                    Text("z z z").font(.custom("Caveat", size: 34 * s).weight(.bold)).foregroundStyle(Theme.honey)
                        .position(x: 276 * s, y: 60 * s)
                }
            }
        }
        .aspectRatio(Self.box.width / Self.box.height, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        switch pose {
        case .hero: return "Sketch of an ant carrying a crumb bigger than its head"
        case .walk: return "Sketch of an ant walking"
        case .alert: return "Sketch of an ant with antennae raised"
        case .rest: return "Sketch of an ant resting"
        }
    }

    // MARK: drawing helpers

    private func shape(_ p: Path) -> ViewBoxShape { ViewBoxShape(path: p, box: Self.box) }
    private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
    private func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry)) }

    /// Ink line with a faint offset second pass, so it reads as hand-drawn.
    private func ink(_ d: String, _ w: CGFloat, _ s: CGFloat, color: Color = Theme.chalk, op: Double = 1, shift: Bool = true) -> some View {
        let p = SVG.path(d, dy: shift ? dy : 0)
        let style = StrokeStyle(lineWidth: w * s, lineCap: .round, lineJoin: .round)
        let ghost = StrokeStyle(lineWidth: max(0.5, w * 0.5) * s, lineCap: .round, lineJoin: .round)
        return ZStack {
            shape(p).stroke(color.opacity(op), style: style)
            shape(p).stroke(color.opacity(op * 0.35), style: ghost).offset(x: 1.3 * s, y: -0.9 * s)
        }
    }

    private func hatch(_ d: String, _ s: CGFloat) -> some View {
        shape(hatchLines(box: Self.box)).stroke(Theme.chalk.opacity(0.5), lineWidth: s)
            .mask(shape(SVG.path(d, dy: dy)).fill())
    }

    private func crumb(_ s: CGFloat) -> some View {
        let outline = SVG.path("M262 56 L292 40 L326 50 L334 82 L318 108 L284 114 L262 98 L254 76 Z")
        return ZStack {
            shape(hatchLines(box: Self.box, angle: -30)).stroke(Theme.honey.opacity(0.7), lineWidth: 1.1 * s)
                .mask(shape(outline).fill())
            shape(outline).stroke(Theme.honey, style: StrokeStyle(lineWidth: 2.2 * s, lineJoin: .round))
            shape(SVG.path("M290 60 L300 80 L292 96 M312 62 L318 84")).stroke(Theme.honey, style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round))
        }
    }

    // MARK: subtle motion

    @ViewBuilder private func twitch<V: View>(_ v: V, anchor: UnitPoint, late: Bool) -> some View {
        if live {
            v.phaseAnimator(late ? [0.0, -5, 2.5, -1.5] : [0.0, -6, 3, -2]) { c, a in
                c.rotationEffect(.degrees(a), anchor: anchor)
            } animation: { a in
                a == 0 ? .easeInOut(duration: late ? 3.1 : 2.8) : .easeInOut(duration: 0.24)
            }
        } else { v }
    }

    @ViewBuilder private func breathe<V: View>(_ v: V) -> some View {
        if live {
            v.phaseAnimator([1.0, 1.018]) { c, k in
                c.scaleEffect(k, anchor: UnitPoint(x: 94 / 340, y: (150 + dy) / 250))
            } animation: { _ in .easeInOut(duration: 1.8) }
        } else { v }
    }

    @ViewBuilder private func bob<V: View>(_ v: V) -> some View {
        if live {
            v.phaseAnimator([0.0, -1.5]) { c, y in c.offset(y: y) } animation: { _ in .easeInOut(duration: 1.8) }
        } else { v }
    }
}

// MARK: - Little logo ant (title bar, progress bars)

struct AntGlyph: View {
    var color: Color = Theme.honey
    private static let box = CGSize(width: 32, height: 20)
    private static let body: Path = {
        var p = Path()
        p.addEllipse(in: CGRect(x: 1, y: 5.5, width: 12, height: 9))
        p.addEllipse(in: CGRect(x: 12.5, y: 7.4, width: 6, height: 5.2))
        p.addEllipse(in: CGRect(x: 18.6, y: 6.6, width: 6.8, height: 6.8))
        return p
    }()
    private static let legs = SVG.path("M14 8l-3-6M16 8l1-6M17 8l4-5M14 12l-3 6M16 12l1 6M17 12l4 5M24 8l3-5M25 9l5-3")

    var body: some View {
        GeometryReader { g in
            let s = g.size.width / Self.box.width
            ZStack {
                ViewBoxShape(path: Self.body, box: Self.box).fill(color)
                ViewBoxShape(path: Self.legs, box: Self.box)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
            }
        }
        .aspectRatio(32 / 20, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Progress as a tunnel, with an ant at the front carrying it home.
struct AntProgress: View {
    let progress: Double
    let color: Color
    let antColor: Color
    var body: some View {
        GeometryReader { g in
            let w = g.size.width * max(0, min(1, progress))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.deep)
                    .overlay(Capsule().stroke(Color.black.opacity(0.45), lineWidth: 1))
                Capsule().fill(color).frame(width: max(w, progress > 0 ? 14 : 0))
                AntGlyph(color: antColor).frame(width: 26, height: 16).offset(x: max(0, w - 6), y: 0)
            }
            .animation(.easeOut(duration: 0.8), value: progress)
        }
        .frame(height: 14)
    }
}

// MARK: - The anthill (Swarm View)

/// Cross-section of an anthill that fills up with the download.
/// Static drawing; only the dotted "marching ants" trails move.
struct Anthill: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var march: CGFloat = 0

    private static let box = CGSize(width: 600, height: 176)
    private static let mound = SVG.path("M6 166 C 105 166, 185 18, 300 18 C 415 18, 495 166, 594 166 Z")

    /// x of the mound's left edge at height y (bezier lookup).
    private static func leftEdge(at y: CGFloat) -> CGFloat {
        var best = CGPoint(x: 6, y: 166)
        for i in 0...200 {
            let t = CGFloat(i) / 200, u = 1 - t
            let px = u*u*u*6 + 3*u*u*t*105 + 3*u*t*t*185 + t*t*t*300
            let py = u*u*u*166 + 3*u*u*t*166 + 3*u*t*t*18 + t*t*t*18
            if abs(py - y) < abs(best.y - y) { best = CGPoint(x: px, y: py) }
        }
        return best.x
    }

    private var top: CGFloat { 166 - 148 * CGFloat(max(0.02, min(1, progress))) }

    private var trails: Path {
        let t = top
        let lx = Self.leftEdge(at: t), rx = 600 - lx
        var p = Path()
        p.move(to: CGPoint(x: -30, y: 167))
        p.addCurve(to: CGPoint(x: lx - 4, y: t + 8), control1: CGPoint(x: 60, y: 167), control2: CGPoint(x: lx - 50, y: t + 70))
        p.addQuadCurve(to: CGPoint(x: 296, y: t - 1), control: CGPoint(x: lx + 60, y: t - 8))
        p.move(to: CGPoint(x: 630, y: 167))
        p.addCurve(to: CGPoint(x: rx + 4, y: t + 8), control1: CGPoint(x: 540, y: 167), control2: CGPoint(x: rx + 50, y: t + 70))
        p.addQuadCurve(to: CGPoint(x: 304, y: t - 1), control: CGPoint(x: rx - 60, y: t - 8))
        return p
    }

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let s = size.width / Self.box.width
                ctx.scaleBy(x: s, y: s)
                ctx.fill(Self.mound, with: .color(Color(hex: 0x191410)))
                var inner = ctx
                inner.clip(to: Self.mound)
                inner.translateBy(x: 0, y: top - 71)
                let strata: [(String, UInt32)] = [
                    ("M0 71 C 160 61, 300 79, 600 69 L600 300 L0 300 Z", 0xE25A2B),
                    ("M0 90 C 140 84, 330 98, 600 88 L600 300 L0 300 Z", 0xC24A23),
                    ("M0 108 C 180 101, 320 115, 600 106 L600 300 L0 300 Z", 0xA23E1E),
                    ("M0 127 C 150 121, 360 133, 600 124 L600 300 L0 300 Z", 0x863319),
                    ("M0 146 C 170 140, 330 152, 600 143 L600 300 L0 300 Z", 0x6A2814),
                ]
                for (d, c) in strata { inner.fill(SVG.path(d), with: .color(Color(hex: c))) }
                // grain
                var y: CGFloat = 62
                var row = 0
                while y < 300 {
                    var x: CGFloat = row % 2 == 0 ? 1.5 : 5
                    while x < 600 {
                        inner.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)),
                                   with: .color(Color(hex: 0xFFD7B0, alpha: 0.26)))
                        x += 7
                    }
                    y += 6; row += 1
                }
                // tunnels and chambers
                let dark = Color(hex: 0x14100C)
                inner.stroke(SVG.path("M300 236 C 300 190, 262 146, 250 132 S 270 108, 236 98"), with: .color(dark.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                inner.stroke(SVG.path("M300 236 C 312 190, 352 144, 360 126 S 336 104, 372 92"), with: .color(dark.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                for r in [CGRect(x: 216, y: 91, width: 40, height: 14), CGRect(x: 354, y: 85.5, width: 36, height: 13),
                          CGRect(x: 234, y: 126, width: 32, height: 12), CGRect(x: 274, y: 150, width: 52, height: 16)] {
                    inner.fill(Path(ellipseIn: r), with: .color(dark))
                }
                inner.stroke(SVG.path("M150 71 C 250 63, 350 77, 450 69"), with: .color(Theme.honey.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                ctx.stroke(Self.mound, with: .color(Theme.lineSoft), style: StrokeStyle(lineWidth: 1.5, dash: [5, 6]))
                ctx.stroke(SVG.path("M-40 168 L640 168"), with: .color(Theme.line), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            MarchingTrail(base: trails, box: Self.box, phase: march)
                .fill(Theme.honey)
        }
        .aspectRatio(Self.box.width / Self.box.height, contentMode: .fit)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { march = 21 }
        }
        .accessibilityElement()
        .accessibilityLabel("Anthill \(Int(progress * 100)) percent built")
    }
}

/// Dotted trail whose dots creep forward: "marching ants".
struct MarchingTrail: Shape {
    let base: Path
    let box: CGSize
    var phase: CGFloat
    var animatableData: CGFloat { get { phase } set { phase = newValue } }
    func path(in rect: CGRect) -> Path {
        let s = rect.width / box.width
        return base.applying(CGAffineTransform(scaleX: s, y: s))
            .strokedPath(StrokeStyle(lineWidth: 3 * s, lineCap: .round, dash: [2.5 * s, 8 * s], dashPhase: -phase * s))
    }
}

// MARK: - Menu bar icon + app icon

enum MenuIcon {
    /// One-line outline ant, as a template image so macOS tints it.
    static let image: NSImage = {
        let size = NSSize(width: 24, height: 15)
        let img = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / 34
            cg.scaleBy(x: s, y: s)
            cg.translateBy(x: 0, y: -1.5)
            var p = Path()
            p.addEllipse(in: CGRect(x: 2, y: 7.5, width: 12, height: 9))
            p.addEllipse(in: CGRect(x: 13.5, y: 8.4, width: 7, height: 5.2))
            p.addEllipse(in: CGRect(x: 21.6, y: 5.6, width: 6.8, height: 6.8))
            p.addPath(SVG.path("M26 6 L28 2 L32 1 M15 13 L13 18 M19 13 L22 18 M9 15 L6 20"))
            cg.addPath(p.cgPath)
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.setLineWidth(2)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.strokePath()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(Theme.honey, lineWidth: 22))
                .frame(width: 824, height: 824)
            AntSketch(pose: .hero, guides: false, animated: false)
                .frame(width: 860)
                .offset(x: -24, y: -20)
                .frame(width: 790, height: 790)
                .clipped()
        }
        .frame(width: 1024, height: 1024)
    }
}

enum IconExporter {
    @MainActor static func export(to path: String) {
        let r = ImageRenderer(content: AppIconArt())
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
