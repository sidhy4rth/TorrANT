import SwiftUI

/// Tiny SVG path-data parser (M L H V C S Q Z, absolute and relative),
/// so the mascot and anthill can reuse the exact paths from the mockups.
enum SVG {
    private enum Token { case cmd(Character), num(CGFloat) }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        var buf = ""
        func flush() {
            if !buf.isEmpty, let v = Double(buf) { out.append(.num(CGFloat(v))) }
            buf = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush(); out.append(.cmd(ch))
            } else if ch == "-" && !buf.isEmpty && !(buf.last == "e" || buf.last == "E") {
                flush(); buf = "-"
            } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
                flush()
            } else if ch == "." && buf.contains(".") && !buf.contains("e") {
                flush(); buf = "."
            } else {
                buf.append(ch)
            }
        }
        flush()
        return out
    }

    static func path(_ d: String, dx: CGFloat = 0, dy: CGFloat = 0) -> Path {
        let t = tokenize(d)
        var i = 0
        var p = Path()
        var cmd: Character = "M"
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastCubic: CGPoint?

        func hasNum() -> Bool {
            if i < t.count, case .num = t[i] { return true }
            return false
        }
        func n() -> CGFloat {
            if i < t.count, case .num(let v) = t[i] { i += 1; return v }
            i += 1
            return 0
        }
        func pt(_ rel: Bool) -> CGPoint {
            let x = n(), y = n()
            return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x + dx, y: y + dy)
        }

        while i < t.count {
            if case .cmd(let c) = t[i] { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            switch cmd.uppercased().first! {
            case "M":
                cur = pt(rel); start = cur; p.move(to: cur)
                cmd = rel ? "l" : "L"
                lastCubic = nil
            case "L":
                cur = pt(rel); p.addLine(to: cur); lastCubic = nil
            case "H":
                let x = n(); cur = CGPoint(x: rel ? cur.x + x : x + dx, y: cur.y); p.addLine(to: cur); lastCubic = nil
            case "V":
                let y = n(); cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y + dy); p.addLine(to: cur); lastCubic = nil
            case "C":
                let c1 = pt(rel), c2 = pt(rel), e = pt(rel)
                p.addCurve(to: e, control1: c1, control2: c2)
                lastCubic = c2; cur = e
            case "S":
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(rel), e = pt(rel)
                p.addCurve(to: e, control1: c1, control2: c2)
                lastCubic = c2; cur = e
            case "Q":
                let c = pt(rel), e = pt(rel)
                p.addQuadCurve(to: e, control: c)
                lastCubic = nil; cur = e
            case "Z":
                p.closeSubpath(); cur = start; lastCubic = nil
                if !hasNum() { continue }
            default:
                i += 1
            }
        }
        return p
    }
}

/// A shape drawn in a fixed "viewBox" coordinate space, scaled to its frame.
struct ViewBoxShape: Shape {
    let path: Path
    let box: CGSize
    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(scaleX: rect.width / box.width, y: rect.height / box.height)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// Straight hatch lines covering a viewBox, for sketch shading.
func hatchLines(box: CGSize, spacing: CGFloat = 5, angle: CGFloat = 35) -> Path {
    var p = Path()
    let rad = angle * .pi / 180
    let len = (box.width + box.height) * 1.5
    var o: CGFloat = -len
    while o < len {
        let a = CGPoint(x: o, y: 0)
        p.move(to: a)
        p.addLine(to: CGPoint(x: a.x - sin(rad) * len, y: a.y + cos(rad) * len))
        o += spacing / cos(rad)
    }
    return p
}
