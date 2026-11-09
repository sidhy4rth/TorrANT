import SwiftUI

// MARK: - The trip, as lines

/// One thing on its way from link to Library, and how far along it is.
struct RelayLine: Identifiable {
    enum Leg: Int { case queued = 0, downloading, toDrive, shelving, done, stuck, idle }

    let id: String
    let title: String
    let leg: Leg
    /// 0…1 within the current leg, read live (it glides between engine readings).
    let progress: (Date) -> Double
    let detail: (Date) -> String
    /// Something is actually happening (bytes moving), so the carrier's legs move.
    let busy: Bool
    var crumb: Crumb? = nil

    /// Where the crumb is on the whole trip: 0 = Queue, 1 = Mac, 2 = Drive, 3 = Library.
    func target(_ now: Date) -> Double {
        let p = min(1, max(0, progress(now)))
        switch leg {
        case .queued, .idle: return 0
        case .downloading, .stuck: return p
        case .toDrive: return 1 + p
        case .shelving: return 2 + p
        case .done: return 3
        }
    }
}

/// Builds the lines from everything TorrANT is doing right now.
@MainActor
enum RelayBoard {
    static func lines() -> [RelayLine] {
        if ProcessInfo.processInfo.environment["TORRANT_DEMO_RELAY"] != nil { return demo() }
        let colony = Colony.shared, up = Uploader.shared, night = NightShift.shared
        var out: [RelayLine] = []

        for c in colony.trail {
            let stuck = c.state == .error
            let detail: (Date) -> String = { now in
                if c.isMetadata { return "finding the swarm…" }
                switch c.state {
                case .paused: return "resting · \(Fmt.liveSize(Double(c.done))) of \(Fmt.liveSize(Double(c.total)))"
                case .waiting: return "waiting its turn"
                case .error: return c.errorMessage ?? "stuck"
                default:
                    return "\(Int(c.liveProgress(now) * 100))% · \(Fmt.liveSpeed(c.liveDown(now))) · \(c.connections) ants"
                }
            }
            out.append(RelayLine(id: "c-\(c.gid)", title: Titles.pretty(c.name), leg: stuck ? .stuck : .downloading,
                                 progress: { c.liveProgress($0) }, detail: detail, busy: c.isMoving, crumb: c))
        }
        for (id, name) in colony.unpacking {
            out.append(RelayLine(id: "u-\(id)", title: Titles.pretty(name), leg: .downloading,
                                 progress: { now in 0.9 + 0.1 * colony.liveUnpack(id, now) },
                                 detail: { _ in "unpacking the zip on the Mac" }, busy: true))
        }
        for j in up.jobs {
            let speed = j.speed
            out.append(RelayLine(id: "j-\(j.id)", title: Titles.pretty(j.name), leg: .toDrive,
                                 progress: { _ in j.size > 0 ? j.done / j.size : 0 },
                                 detail: { _ in "flying to Drive · \(j.size > 0 ? Int(j.done / j.size * 100) : 0)% · \(Fmt.liveSpeed(speed))" },
                                 busy: true))
        }
        for (id, name) in colony.carrying where !up.jobs.contains(where: { $0.name == name }) {
            out.append(RelayLine(id: "m-\(id)", title: Titles.pretty(name), leg: .toDrive, progress: { _ in 0.5 },
                                 detail: { _ in "handing it to Google Drive" }, busy: true))
        }
        let start = night.nextStart()
        for it in night.waiting {
            out.append(RelayLine(id: "n-\(it.id)", title: Titles.pretty(it.name), leg: .queued, progress: { _ in 0 },
                                 detail: { _ in night.on ? "asleep till \(start.formatted(date: .omitted, time: .shortened))" : "waiting for the night shift" },
                                 busy: false))
        }
        // Arrivals from the last 15 minutes stay on the board, shelved.
        for h in colony.hill where Date().timeIntervalSince(h.date) < 900 {
            out.append(RelayLine(id: "h-\(h.id)", title: Titles.pretty(h.name), leg: .done, progress: { _ in 1 },
                                 detail: { _ in "in your Library ✓" }, busy: false))
        }
        return out
    }

    /// Pretend lines for screenshots and testing (TORRANT_DEMO_RELAY=1); never touches real downloads.
    static func demo() -> [RelayLine] {
        func loop(_ secs: Double, _ off: Double) -> (Date) -> Double {
            { now in ((now.timeIntervalSinceReferenceDate + off) / secs).truncatingRemainder(dividingBy: 1) }
        }
        func leg(_ secs: Double, _ off: Double, _ now: Date) -> (RelayLine.Leg, Double) {
            let v = loop(secs, off)(now) * 3.4
            if v < 0.4 { return (.queued, 0) }
            let w = v - 0.4
            return w < 1 ? (.downloading, w) : w < 2 ? (.toDrive, w - 1) : (.shelving, w - 2)
        }
        let now = Date()
        func line(_ id: String, _ title: String, _ secs: Double, _ off: Double) -> RelayLine {
            let (l, _) = leg(secs, off, now)
            return RelayLine(id: id, title: Titles.pretty(title), leg: l, progress: { leg(secs, off, $0).1 },
                             detail: { d in
                                 let (l, p) = leg(secs, off, d)
                                 switch l {
                                 case .queued: return "asleep till 1:00 AM"
                                 case .downloading: return "\(Int(p * 100))% · 6.2 MB/s · 41 ants"
                                 case .toDrive: return "flying to Drive · \(Int(p * 100))%"
                                 default: return "green ant shelving it"
                                 }
                             }, busy: l != .queued)
        }
        return [line("d1", "Marshals.S01E05.1080p.WEB-DL.mkv", 60, 14), line("d2", "Carrie.S01E05.1080p.mkv", 75, 40),
                line("d3", "Primetime.2026.1080p.mkv", 50, 34),
                RelayLine(id: "d4", title: Titles.pretty("Campus.Drivers.S01E07.mkv"), leg: .queued, progress: { _ in 0 }, detail: { _ in "asleep till 1:00 AM" }, busy: false),
                RelayLine(id: "d5", title: Titles.pretty("Old.Torrent.With.No.Seeds.2019.mkv"), leg: .stuck, progress: { _ in 0.31 }, detail: { _ in "stuck: nobody is sharing it" }, busy: false),
                RelayLine(id: "d6", title: Titles.pretty("War.Machine.2026.1080p.mkv"), leg: .done, progress: { _ in 1 }, detail: { _ in "in your Library ✓" }, busy: false)]
    }
}

// MARK: - Lanes

/// Station names over the tracks, then one lane per line.
struct RelayLanes: View {
    let lines: [RelayLine]
    static let infoWidth: CGFloat = 270
    static let controls: CGFloat = 76

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                let geo = RelayGeometry(width: g.size.width - Self.infoWidth - Self.controls)
                ZStack(alignment: .topLeading) {
                    ForEach(0..<4, id: \.self) { k in
                        Text(["Queue", "Mac", "Google Drive", "Library"][k])
                            .font(Theme.display(14)).foregroundStyle(Theme.text.opacity(0.85))
                            .fixedSize()
                            .position(x: Self.infoWidth + geo.x(Double(k)), y: 9)
                    }
                    ForEach(0..<3, id: \.self) { k in
                        HStack(spacing: 5) {
                            Circle().fill(RelayCrew.colors[k + 1]).frame(width: 7, height: 7)
                            Text(["red ant · downloading", "amber ant · uploading", "green ant · shelving"][k])
                                .font(Theme.body(11, .bold)).foregroundStyle(RelayCrew.colors[k + 1])
                        }
                        .fixedSize()
                        .position(x: Self.infoWidth + geo.x(Double(k) + 0.5), y: 29)
                    }
                }
            }
            .frame(height: 40)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(lines) { l in RelayRow(line: l) }
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
        }
    }
}

/// Where the four stations sit across a track of a given width.
struct RelayGeometry {
    let width: CGFloat
    var left: CGFloat { 30 }
    var right: CGFloat { max(left + 90, width - 30) }
    var gap: CGFloat { (right - left) / 3 }
    func x(_ pos: Double) -> CGFloat { left + CGFloat(pos) * gap }
}

private struct RelayRow: View {
    let line: RelayLine
    @State private var hover = false
    @State private var shown = false
    private var colony: Colony { Colony.shared }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5).fill(RelayCrew.legColor(line.leg).opacity(0.85))
                    .frame(width: 6, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.title).font(Theme.body(14, .semibold)).lineLimit(1).truncationMode(.middle)
                    LiveLabel(live: line.busy, font: LiveFont.body(12, 600), color: RelayCrew.legColor(line.leg), align: .left) { line.detail($0) }
                        .frame(height: 16)
                }
            }
            .padding(.leading, 10)
            .frame(width: RelayLanes.infoWidth, alignment: .leading)
            RelayTrack(line: line)
                .frame(height: 64)
            controls.frame(width: RelayLanes.controls)
        }
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Theme.surface : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture { if let c = line.crumb { colony.openGID = c.gid } }
        .contextMenu { menu }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 10)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shown = true } }
    }

    @ViewBuilder private var controls: some View {
        if let c = line.crumb {
            HStack(spacing: 6) {
                if c.state == .paused || c.state == .waiting {
                    round("play.fill", "Wake the ants") { await colony.resume(c) }
                } else if c.state == .error {
                    round("arrow.clockwise", "Try again") { await colony.retry(c) }
                } else {
                    round("pause.fill", "Let the ants rest") { await colony.rest(c) }
                }
                round("xmark", "Drop it") { await colony.remove(c, deleteFiles: false) }
            }
            .opacity(hover ? 1 : 0)
        } else { Color.clear }
    }

    private func round(_ icon: String, _ help: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.surface2))
        }
        .buttonStyle(.plain).foregroundStyle(Theme.text).help(help).accessibilityLabel(help)
    }

    @ViewBuilder private var menu: some View {
        if let c = line.crumb {
            Button("Open details") { colony.openGID = c.gid }
            if c.state == .paused { Button("Wake the ants") { Task { await colony.resume(c) } } }
            else { Button("Let the ants rest") { Task { await colony.rest(c) } } }
            Button("Show in Finder") { colony.reveal(c.homePath) }
            if let s = c.source {
                Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
            }
            Divider()
            Button("Drop it") { Task { await colony.remove(c, deleteFiles: false) } }
            Button("Drop it and bin the files") { Task { await colony.remove(c, deleteFiles: true) } }
        }
    }
}

// MARK: - The track and its ants

enum RelayCrew {
    /// Night, carrier, flyer, librarian.
    static let colors: [Color] = [Theme.nightAnt, Theme.carrierAnt, Theme.flyerAnt, Theme.librarianAnt]
    static let stuck = Color(hex: 0x8A7F6E)

    static func legColor(_ leg: RelayLine.Leg) -> Color {
        switch leg {
        case .queued, .idle: return Theme.nightAnt
        case .downloading: return Theme.carrierAnt
        case .toDrive: return Theme.flyerAnt
        case .shelving, .done: return Theme.librarianAnt
        case .stuck: return Theme.muted
        }
    }
}

/// Remembers where each lane's crumb is drawn, so it glides to new readings instead of jumping,
/// and when it crossed a station (to play the hop between ants).
@MainActor
final class RelayMotion {
    var pos: Double?
    var last = Date()
    var hopAt: Date?
    var hopStation = 0
    var lastLeg: RelayLine.Leg?

    func step(to target: Double, leg: RelayLine.Leg, now: Date) -> Double {
        guard let p = pos else { pos = target; last = now; lastLeg = leg; return target }
        let dt = min(0.1, max(0, now.timeIntervalSince(last)))
        last = now
        // Critically damped glide: quick to follow, never overshoots.
        let next = p + (target - p) * (1 - exp(-dt * 3.2))
        let crossed = Int(floor(next + 0.0001)) > Int(floor(p + 0.0001)) && next > p
        if crossed { hopAt = now; hopStation = Int(floor(next + 0.0001)) }
        if lastLeg == .queued && leg == .downloading { hopAt = now; hopStation = 0 }
        lastLeg = leg
        pos = abs(target - next) < 0.0004 ? target : next
        return pos!
    }

    func settled(_ target: Double) -> Bool { pos.map { abs($0 - target) < 0.0004 } ?? false }
    func hopping(_ now: Date) -> Bool { hopAt.map { now.timeIntervalSince($0) < 0.65 } ?? false }
}

struct RelayTrack: View {
    let line: RelayLine
    @State private var motion = RelayMotion()
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        // Redraws every frame only while something moves; still lanes cost nothing.
        let animate = !reduce && (line.busy || !motion.settled(line.target(Date())) || motion.hopping(Date()) || line.leg == .queued)
        TimelineView(.animation(minimumInterval: nil, paused: !animate)) { tl in
            Canvas { ctx, size in
                draw(&ctx, size, tl.date)
            }
        }
        .accessibilityLabel("\(line.title): \(line.detail(Date()))")
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ now: Date) {
        let geo = RelayGeometry(width: size.width)
        let y: CGFloat = 36
        let target = line.target(now)
        let pos = reduce ? target : motion.step(to: target, leg: line.leg, now: now)
        let t = now.timeIntervalSinceReferenceDate
        let moving = !reduce && (line.busy || !motion.settled(target))
        let c = RelayCrew.colors

        // Track, coloured as far as the crumb has come.
        ctx.fill(Path(roundedRect: CGRect(x: geo.left, y: y - 2, width: geo.right - geo.left, height: 4), cornerRadius: 2), with: .color(Theme.track))
        for k in 0..<3 {
            let f = min(1, max(0, pos - Double(k)))
            if f > 0 {
                ctx.fill(Path(roundedRect: CGRect(x: geo.x(Double(k)), y: y - 2, width: geo.gap * f, height: 4), cornerRadius: 2),
                         with: .color(line.leg == .stuck ? RelayCrew.stuck : c[k + 1]))
            }
        }
        for k in 0..<4 {
            let reached = line.leg != .queued && line.leg != .idle && pos >= Double(k) - 0.0001
            let r = CGRect(x: geo.x(Double(k)) - 6, y: y - 6, width: 12, height: 12)
            ctx.fill(Path(ellipseIn: r), with: .color(Theme.soil))
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: 1.5, dy: 1.5)), with: .color(reached ? c[k] : Theme.stationDot), lineWidth: 3)
        }

        let leg = line.leg
        let walk = moving ? t : nil
        let stuck = leg == .stuck
        let hasCrumb = leg != .idle
        let hop = motion.hopping(now) ? motion.hopAt.map { min(1, now.timeIntervalSince($0) / 0.6) } : nil
        let carrierSeg = min(2, Int(floor(pos)))   // 0 = red, 1 = amber, 2 = green
        var crumbAt: CGPoint?

        // Night ant: holds the crumb in the queue, then turns away.
        let queued = leg == .queued || leg == .idle
        RelayAnt.draw(&ctx, x: geo.x(0) - 8, base: y, color: c[0], facing: queued ? 1 : -1, alpha: queued ? 1 : 0.45, legs: nil)
        if leg == .queued { crumbAt = RelayAnt.back(x: geo.x(0) - 8, base: y, facing: 1) }
        if leg == .queued, !reduce {
            for i in 0..<2 {
                let ph = (t / 2.2 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                ctx.opacity = sin(ph * .pi)
                ctx.draw(Text("z").font(Theme.display(12)).foregroundColor(c[0]), at: CGPoint(x: geo.x(0) + 4 + ph * 10, y: y - 26 - ph * 16))
                ctx.opacity = 1
            }
        }

        // Carrier (red): waits by the queue, carries Queue → Mac, rests at the Mac.
        if queued {
            RelayAnt.draw(&ctx, x: geo.x(0) + 24, base: y, color: c[1], facing: -1, alpha: 1, legs: nil)
        } else if carrierSeg == 0 && pos < 1 {
            let x = geo.x(pos)
            RelayAnt.draw(&ctx, x: x, base: y, color: stuck ? RelayCrew.stuck : c[1], facing: 1, alpha: 1, legs: stuck ? nil : walk)
            if stuck { RelayAnt.bang(&ctx, x: x, base: y) }
            crumbAt = RelayAnt.back(x: x, base: y, facing: 1)
        } else {
            RelayAnt.draw(&ctx, x: geo.x(1) - 24, base: y, color: c[1], facing: -1, alpha: 0.45, legs: nil)
        }

        // Flyer (amber, wings): waits at the Mac, flies Mac → Drive with a gentle lift, rests at Drive.
        if pos < 1 || queued {
            RelayAnt.draw(&ctx, x: geo.x(1) + 24, base: y, color: c[2], facing: -1, alpha: 1, legs: nil, wings: .folded)
        } else if pos < 2 {
            let f = pos - 1
            let lift = -11 * sin(.pi * f)
            let x = geo.x(pos)
            RelayAnt.draw(&ctx, x: x, base: y + lift, color: c[2], facing: 1, alpha: 1, legs: nil,
                          wings: moving ? .flapping(t) : .folded)
            crumbAt = RelayAnt.back(x: x, base: y + lift, facing: 1)
        } else {
            RelayAnt.draw(&ctx, x: geo.x(2) - 24, base: y, color: c[2], facing: -1, alpha: 0.45, legs: nil, wings: .folded)
        }

        // Librarian (green): waits at Drive, carries Drive → Library, shelves it.
        if pos < 2 || queued {
            RelayAnt.draw(&ctx, x: geo.x(2) + 24, base: y, color: c[3], facing: -1, alpha: 1, legs: nil)
        } else if pos < 3 {
            let x = geo.x(pos)
            RelayAnt.draw(&ctx, x: x, base: y, color: c[3], facing: 1, alpha: 1, legs: walk)
            crumbAt = RelayAnt.back(x: x, base: y, facing: 1)
        } else {
            RelayAnt.draw(&ctx, x: geo.x(3) - 10, base: y, color: c[3], facing: 1, alpha: 1, legs: nil)
            let r = CGRect(x: geo.x(3) + 10, y: y - 12, width: 24, height: 24)
            ctx.fill(Path(ellipseIn: r), with: .color(c[3]))
            ctx.draw(Text("✓").font(Theme.body(13, .heavy)).foregroundColor(Theme.soil), at: CGPoint(x: r.midX, y: r.midY))
        }

        // The crumb: on the carrier's back, or mid-hop between two ants.
        guard hasCrumb, leg != .done else { return }
        if let h = hop, var to = crumbAt {
            let k = motion.hopStation
            let fromX = k == 0 ? geo.x(0) - 8 : geo.x(Double(k)) - 24
            let from = RelayAnt.back(x: fromX, base: y, facing: k == 0 ? 1 : -1)
            let e = h < 0.5 ? 2 * h * h : 1 - pow(-2 * h + 2, 2) / 2
            to = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e - 22 * sin(.pi * h))
            RelayAnt.crumb(&ctx, at: to, turn: h * 2 * .pi)
        } else if let at = crumbAt {
            RelayAnt.crumb(&ctx, at: at, turn: 0)
        }
    }
}

/// Drawing one flat ant (34 × 24 units) in a Canvas.
enum RelayAnt {
    enum Wings { case none, folded, flapping(Double) }

    static func back(x: CGFloat, base: CGFloat, facing: CGFloat) -> CGPoint {
        CGPoint(x: x + facing * (7 - 17), y: base - 21 + 6)
    }

    static func draw(_ ctx: inout GraphicsContext, x: CGFloat, base: CGFloat, color: Color, facing: CGFloat,
                     alpha: Double, legs: Double?, wings: Wings = .none) {
        var g = ctx
        g.opacity = alpha
        g.translateBy(x: x, y: base - 21)
        g.scaleBy(x: facing, y: 1)
        g.translateBy(x: -17, y: 0)
        switch wings {
        case .folded:
            g.fill(Path(ellipseIn: CGRect(x: 8, y: 4, width: 14, height: 6)), with: .color(Theme.crumbFill.opacity(0.35)))
        case .flapping(let t):
            let s = 0.25 + 0.75 * abs(sin(t * 2 * .pi / 0.26))
            g.fill(Path(ellipseIn: CGRect(x: 7, y: 9.5 - 9 * s, width: 16, height: 9 * s)), with: .color(Theme.crumbFill.opacity(0.8)))
        case .none: break
        }
        let stroke = StrokeStyle(lineWidth: 1.7, lineCap: .round)
        let swing = legs.map { sin($0 * 2 * .pi / 0.28) * 0.35 } ?? 0
        var legPath = Path()
        for (i, (sx, sy, ex, ey)) in [(11.0, 15.0, 8.0, 21.0), (16, 16, 16, 21), (19, 15, 22, 21)].enumerated() {
            let a = (i == 1 ? -swing : swing)
            let dx = ex - sx, dy = ey - sy
            legPath.move(to: CGPoint(x: sx, y: sy))
            legPath.addLine(to: CGPoint(x: sx + dx * cos(a) - dy * sin(a), y: sy + dx * sin(a) + dy * cos(a)))
        }
        legPath.move(to: CGPoint(x: 26, y: 8)); legPath.addLine(to: CGPoint(x: 29, y: 2))
        legPath.move(to: CGPoint(x: 24, y: 8)); legPath.addLine(to: CGPoint(x: 23, y: 2))
        g.stroke(legPath, with: .color(color), style: stroke)
        g.fill(Path(ellipseIn: CGRect(x: 1, y: 9, width: 12, height: 10)), with: .color(color))
        g.fill(Path(ellipseIn: CGRect(x: 13, y: 11, width: 6, height: 6)), with: .color(color))
        g.fill(Path(ellipseIn: CGRect(x: 20.4, y: 8.9, width: 7.2, height: 7.2)), with: .color(color))
    }

    static func crumb(_ ctx: inout GraphicsContext, at p: CGPoint, turn: Double) {
        var g = ctx
        g.translateBy(x: p.x, y: p.y)
        g.rotate(by: .radians(turn))
        g.fill(Path(roundedRect: CGRect(x: -5, y: -4, width: 10, height: 8), cornerRadius: 2), with: .color(Theme.crumbFill))
    }

    /// The "something's wrong" mark: a white circle with "!".
    static func bang(_ ctx: inout GraphicsContext, x: CGFloat, base: CGFloat) {
        let r = CGRect(x: x + 8, y: base - 36, width: 14, height: 14)
        ctx.fill(Path(ellipseIn: r), with: .color(.white))
        ctx.draw(Text("!").font(Theme.body(11, .heavy)).foregroundColor(Theme.soil), at: CGPoint(x: r.midX, y: r.midY))
    }
}
