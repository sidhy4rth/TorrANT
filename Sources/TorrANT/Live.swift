import SwiftUI

/// The engine reports 4 times a second. Between reports the screen keeps
/// moving: speeds glide from the last reading to the new one, and sizes /
/// progress keep counting up at the current speed. Redrawn every frame.
enum Live {
    static let readingGap: TimeInterval = 0.25

    static func glide(from a: Int, to b: Int, since t: Date, now: Date) -> Double {
        let k = min(1, max(0, now.timeIntervalSince(t) / readingGap))
        let eased = 1 - pow(1 - k, 3)
        return Double(a) + Double(b - a) * eased
    }
}

extension Crumb {
    var isMoving: Bool { state == .active && !isMetadata }

    func liveDown(_ now: Date) -> Double {
        isMoving ? Live.glide(from: prevDown, to: down, since: sampledAt, now: now) : Double(down)
    }

    func liveDone(_ now: Date) -> Double {
        guard isMoving, total > 0 else { return ForwardOnly.shared.set(gid, Double(done)) }
        let elapsed = min(0.6, max(0, now.timeIntervalSince(sampledAt)))
        let guess = Double(done) + liveDown(now) * elapsed
        return ForwardOnly.shared.step(gid, toward: guess, atLeast: Double(done), atMost: Double(total))
    }

    func liveProgress(_ now: Date) -> Double {
        total > 0 ? min(1, liveDone(now) / Double(total)) : 0
    }

    func liveEta(_ now: Date) -> TimeInterval? {
        let s = liveDown(now)
        guard s > 1, total > 0 else { return nil }
        return (Double(total) - liveDone(now)) / s
    }
}

extension Colony {
    func liveDown(_ now: Date) -> Double { Live.glide(from: prevDown, to: down, since: speedAt, now: now) }
    func liveUp(_ now: Date) -> Double { Live.glide(from: prevUp, to: up, since: speedAt, now: now) }
    func liveSession(_ now: Date) -> Double {
        let guess = Double(sessionBytes) + liveDown(now) * min(0.6, max(0, now.timeIntervalSince(speedAt)))
        return ForwardOnly.shared.step("session", toward: guess, atLeast: Double(sessionBytes), atMost: .infinity)
    }
    var anythingMoving: Bool { down > 0 || prevDown > 0 || up > 0 || prevUp > 0 }
}

/// Remembers what each bar/counter last showed so it never moves backwards.
/// If the estimate runs ahead of the engine, the value simply holds until
/// the real number catches up — no snapping back, no "looping" ant.
final class ForwardOnly: @unchecked Sendable {
    static let shared = ForwardOnly()
    private var shown: [String: Double] = [:]

    func step(_ key: String, toward guess: Double, atLeast real: Double, atMost cap: Double) -> Double {
        var v = shown[key] ?? real
        if real > v { v = real }                       // engine is ahead: catch up
        if guess > v { v += (guess - v) * 0.3 }        // glide forward, never back
        v = min(v, cap)
        shown[key] = v
        return v
    }

    @discardableResult
    func set(_ key: String, _ value: Double) -> Double {
        shown[key] = value
        return value
    }
}

extension Fmt {
    /// Sizes that visibly count: "3.904 GB", "412.3 MB".
    static func liveSize(_ b: Double) -> String {
        if b >= 1e9 { return String(format: "%.3f GB", b / 1e9) }
        if b >= 1e6 { return String(format: "%.1f MB", b / 1e6) }
        return String(format: "%.0f KB", b / 1e3)
    }
    static func liveSpeed(_ bps: Double) -> String {
        if bps >= 1e6 { return String(format: "%.1f MB/s", bps / 1e6) }
        return String(format: "%.0f KB/s", max(0, bps) / 1e3)
    }
    /// "2:41", "1h 02m", "3 days"
    static func clock(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite, t >= 0 else { return "—" }
        let s = Int(t)
        if s >= 86400 { return "\(s / 86400) days" }
        if s >= 3600 { return "\(s / 3600)h " + String(format: "%02dm", (s % 3600) / 60) }
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
    /// Value and unit for the odometer: (18.4, "MB/s")
    static func odoSpeed(_ bps: Double) -> (Double, String) {
        bps >= 1e6 ? (bps / 1e6, "MB/s") : (max(0, bps) / 1e3, "KB/s")
    }
}

/// Digits roll like a car odometer (one decimal place).
struct Odometer: View {
    let value: Double
    let size: CGFloat
    var color: Color = Theme.text

    private struct Col: Identifiable { let id: Int; let dot: Bool; let pos: Double }

    private var cols: [Col] {
        let x = max(0, value) * 10
        let n = max(2, String(Int(x.rounded(.down))).count)
        var raw: [Double] = []
        var roll = max(0, x.truncatingRemainder(dividingBy: 10) - 9)
        raw.append(x.truncatingRemainder(dividingBy: 10))
        for k in 1..<n {
            let base = Int(x / pow(10, Double(k))) % 10
            raw.append(Double(base) + roll)
            if base != 9 { roll = 0 }
        }
        var out: [Col] = []
        for (i, pos) in raw.reversed().enumerated() {
            if i == raw.count - 1 { out.append(Col(id: 100, dot: true, pos: 0)) }
            out.append(Col(id: raw.count - i, dot: false, pos: pos))
        }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(cols) { c in
                if c.dot {
                    Text(".").font(Theme.display(size)).frame(width: size * 0.26)
                } else {
                    // Only the digit showing and the one rolling in are drawn.
                    let row = size * 1.2
                    let whole = Int(c.pos.rounded(.down))
                    let frac = c.pos - Double(whole)
                    VStack(spacing: 0) {
                        Text("\(whole % 10)").font(Theme.display(size)).frame(height: row)
                        Text("\((whole + 1) % 10)").font(Theme.display(size)).frame(height: row)
                    }
                    .offset(y: -frac * row)
                    .frame(width: size * 0.6, height: row, alignment: .top)
                    .clipped()
                }
            }
        }
        .foregroundStyle(color)
        .accessibilityElement()
        .accessibilityLabel(String(format: "%.1f", value))
    }
}

/// Redraws its content every frame while something is moving.
struct EveryFrame<Content: View>: View {
    var active: Bool
    var fps: Double = 60
    @ViewBuilder var content: (Date) -> Content
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !active)) { ctx in
            content(ctx.date)
        }
    }
}

/// Progress tunnel + ant, drawn in one Canvas pass (cheap at 60 fps).
struct LiveBar: View {
    let progress: Double
    let color: Color
    let ant: Color

    var body: some View {
        Canvas { ctx, size in
            let h: CGFloat = 14
            let y = (size.height - h) / 2
            let track = CGRect(x: 0, y: y, width: size.width, height: h)
            ctx.fill(Path(roundedRect: track, cornerRadius: h / 2), with: .color(Theme.deep))
            ctx.stroke(Path(roundedRect: track, cornerRadius: h / 2), with: .color(.black.opacity(0.45)), lineWidth: 1)
            let p = max(0, min(1, progress))
            let w = p > 0 ? max(h, size.width * p) : 0
            if w > 0 {
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: h), cornerRadius: h / 2), with: .color(color))
            }
            var g = ctx
            g.translateBy(x: max(0, min(size.width - 26, w - 6)), y: (size.height - 16) / 2)
            g.scaleBy(x: 26.0 / 32.0, y: 16.0 / 20.0)
            g.fill(AntGlyph.bodyPath, with: .color(ant))
            g.stroke(AntGlyph.legsPath, with: .color(ant), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("\(Int(progress * 100)) percent")
    }
}
