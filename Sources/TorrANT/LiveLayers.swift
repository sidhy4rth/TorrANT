import AppKit
import SwiftUI
import QuartzCore

// Live numbers and bars drawn with Core Animation layers, ticked by the
// display's refresh. Changing them never re-lays-out the SwiftUI window,
// so 60 fps costs very little CPU.

class TickingView: NSView {
    private var link: CADisplayLink?
    var isLive = false { didSet { if oldValue != isLive { updateLink() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    private func updateLink() {
        if window != nil && isLive {
            if link == nil {
                let l = displayLink(target: self, selector: #selector(step))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                l.add(to: .main, forMode: .common)
                link = l
            }
        } else {
            link?.invalidate()
            link = nil
        }
        tick()
    }

    @objc private func step() { tick() }
    func tick() {}

    override func layout() {
        super.layout()
        tick()
    }
}

enum LiveFont {
    static let wght = 0x77676874 // 'wght' variation axis

    static func make(_ family: String, _ size: CGFloat, weight: CGFloat) -> NSFont {
        let d = NSFontDescriptor(fontAttributes: [
            .family: family,
            .variation: [NSNumber(value: wght): NSNumber(value: Double(weight))],
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: d, size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }
    static func display(_ size: CGFloat) -> NSFont { make("Bricolage Grotesque", size, weight: 800) }
    static func body(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont { make("Figtree", size, weight: weight) }
}

/// Draws into a 2x bitmap with a top-left origin and returns a CGImage.
func renderImage(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                                     pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
}

// MARK: - Text that counts

final class LiveLabelView: TickingView {
    let field = NSTextField(labelWithString: "")
    var text: (Date) -> String = { _ in "" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        let h = field.intrinsicContentSize.height
        field.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        super.layout()
    }

    override func tick() {
        let s = text(Date())
        if field.stringValue != s { field.stringValue = s }
    }
}

struct LiveLabel: NSViewRepresentable {
    var live: Bool
    var font: NSFont
    var color: Color
    var align: NSTextAlignment = .left
    var text: (Date) -> String

    func makeNSView(context: Context) -> LiveLabelView {
        let v = LiveLabelView()
        v.field.font = font
        v.field.alignment = align
        return v
    }

    func updateNSView(_ v: LiveLabelView, context: Context) {
        v.text = text
        v.field.textColor = NSColor(color)
        v.field.font = font
        v.isLive = live
        v.tick()
    }
}

// MARK: - Progress tunnel with the ant

enum AntImage {
    private static var cache: [String: CGImage] = [:]
    static func make(_ color: NSColor) -> CGImage? {
        let key = color.description
        if let c = cache[key] { return c }
        let img = renderImage(CGSize(width: 26, height: 16)) { cg in
            cg.scaleBy(x: 26.0 / 32.0, y: 16.0 / 20.0)
            cg.addPath(AntGlyph.bodyPath.cgPath)
            cg.setFillColor(color.cgColor)
            cg.fillPath()
            cg.addPath(AntGlyph.legsPath.cgPath)
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(1.8)
            cg.setLineCap(.round)
            cg.strokePath()
        }
        cache[key] = img
        return img
    }
}

final class LiveBarView: TickingView {
    private let track = CALayer()
    private let fill = CALayer()
    private let ant = CALayer()
    var progress: (Date) -> Double = { _ in 0 }
    var barColor: NSColor = .red { didSet { fill.backgroundColor = barColor.cgColor } }
    var antColor: NSColor = .white {
        didSet { if oldValue != antColor { ant.contents = AntImage.make(antColor) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = false
        track.backgroundColor = NSColor(Theme.deep).cgColor
        track.borderColor = NSColor.black.withAlphaComponent(0.45).cgColor
        track.borderWidth = 1
        ant.contentsGravity = .resizeAspect
        ant.contents = AntImage.make(antColor)
        for l in [track, fill, ant] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func tick() {
        let h: CGFloat = 14
        let w = bounds.width
        let y = (bounds.height - h) / 2
        let p = max(0, min(1, progress(Date())))
        let fw = p > 0 ? max(h, w * p) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 0, y: y, width: w, height: h)
        track.cornerRadius = h / 2
        fill.frame = CGRect(x: 0, y: y, width: fw, height: h)
        fill.cornerRadius = h / 2
        ant.frame = CGRect(x: max(0, min(w - 26, fw - 6)), y: (bounds.height - 16) / 2, width: 26, height: 16)
        CATransaction.commit()
    }
}

struct LiveBarLayer: NSViewRepresentable {
    var live: Bool
    var color: Color
    var ant: Color
    var progress: (Date) -> Double

    func makeNSView(context: Context) -> LiveBarView { LiveBarView() }
    func updateNSView(_ v: LiveBarView, context: Context) {
        v.progress = progress
        v.barColor = NSColor(color)
        v.antColor = NSColor(ant)
        v.isLive = live
        v.tick()
    }
}

// MARK: - Odometer

final class OdometerView: TickingView {
    var value: (Date) -> (Double, String) = { _ in (0, "") }
    var size: CGFloat = 38 { didSet { if oldValue != size { strip = nil } } }
    var color: NSColor = .white { didSet { if oldValue != color { strip = nil } } }

    private var strip: CGImage?
    private var cellW: CGFloat = 0
    private var row: CGFloat = 0
    private var cols: [(clip: CALayer, digits: CALayer)] = []
    private let dot = CATextLayer()
    private let unit = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for t in [dot, unit] {
            t.contentsScale = 2
            layer?.addSublayer(t)
        }
        dot.string = "."
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildStrip() {
        let font = LiveFont.display(size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        cellW = ceil((0...9).map { NSAttributedString(string: "\($0)", attributes: attrs).size().width }.max() ?? size * 0.6)
        row = ceil(size * 1.2)
        let lineH = NSAttributedString(string: "0", attributes: attrs).size().height
        strip = renderImage(CGSize(width: cellW, height: row * 11)) { _ in
            for k in 0...10 {
                let s = NSAttributedString(string: "\(k % 10)", attributes: attrs)
                let w = s.size().width
                s.draw(at: CGPoint(x: (cellW - w) / 2, y: CGFloat(k) * row + (row - lineH) / 2))
            }
        }
        for c in cols { c.clip.removeFromSuperlayer() }
        cols = []
        dot.font = font
        dot.fontSize = size
        dot.foregroundColor = color.cgColor
        unit.font = LiveFont.display(size * 0.45)
        unit.fontSize = size * 0.45
        unit.foregroundColor = color.cgColor
    }

    /// Rolling positions, most significant digit first (one decimal place).
    static func positions(_ v: Double) -> [Double] {
        let x = max(0, v) * 10
        let n = max(2, String(Int(x.rounded(.down))).count)
        var raw: [Double] = [x.truncatingRemainder(dividingBy: 10)]
        var roll = max(0, raw[0] - 9)
        for k in 1..<n {
            let base = Int(x / pow(10, Double(k))) % 10
            raw.append(Double(base) + roll)
            if base != 9 { roll = 0 }
        }
        return raw.reversed()
    }

    override func tick() {
        if strip == nil { buildStrip() }
        guard let strip else { return }
        let (v, u) = value(Date())
        let pos = Self.positions(v)
        while cols.count < pos.count {
            let clip = CALayer()
            clip.masksToBounds = true
            let digits = CALayer()
            digits.contents = strip
            digits.contentsScale = 2
            clip.addSublayer(digits)
            layer?.addSublayer(clip)
            cols.append((clip, digits))
        }
        while cols.count > pos.count { cols.removeLast().clip.removeFromSuperlayer() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let top = (bounds.height - row) / 2
        var x: CGFloat = 0
        let dotW = ceil(size * 0.26)
        for (i, p) in pos.enumerated() {
            if i == pos.count - 1 {
                dot.frame = CGRect(x: x, y: top, width: dotW, height: row)
                x += dotW
            }
            let c = cols[i]
            c.clip.frame = CGRect(x: x, y: top, width: cellW, height: row)
            // layer coords start bottom-left: slide the strip up by p rows
            c.digits.frame = CGRect(x: 0, y: row - row * 11 + CGFloat(p) * row, width: cellW, height: row * 11)
            x += cellW
        }
        if (unit.string as? String) != u { unit.string = u }
        let uh = size * 0.6
        unit.frame = CGRect(x: x + 6, y: top + 4, width: 60, height: uh)
        CATransaction.commit()
    }
}

struct OdometerLayer: NSViewRepresentable {
    var live: Bool
    var size: CGFloat
    var color: Color
    var value: (Date) -> (Double, String)

    func makeNSView(context: Context) -> OdometerView { OdometerView() }
    func updateNSView(_ v: OdometerView, context: Context) {
        v.size = size
        v.color = NSColor(color)
        v.value = value
        v.isLive = live
        v.tick()
    }
}
