import SwiftUI

/// Screen 3: Swarm View — one download up close, with the anthill.
struct SwarmView: View {
    let gid: String
    @Environment(\.dismiss) private var dismiss
    @State private var peers: [Peer] = []
    @State private var picks: Set<Int> = []
    @State private var picksLoaded = false

    private var colony: Colony { Colony.shared }
    private var crumb: Crumb? {
        colony.trail.first { $0.gid == gid } ?? colony.seeding.first { $0.gid == gid }
    }

    /// Whether other people can connect to us (the router opened the port) or only we to them.
    private var doorText: String {
        switch PortMapper.shared.door {
        case .checking: "Checking the door…"
        case .open(let how): "Door open (\(how)): other colonies can reach us"
        case .closed: "Door closed: this network doesn't let others reach us, so we only reach out"
        }
    }

    var body: some View {
        Group {
            if let c = crumb { content(c) } else { gone }
        }
        .frame(width: 980, height: 720)
        .background(SoilBackground())
        .foregroundStyle(Theme.text)
        .task { await loopPeers() }
    }

    private var gone: some View {
        VStack(spacing: 14) {
            AntSketch(pose: .hero).frame(width: 260)
            Text("It's home, or it's gone.").font(Theme.display(24))
            Button("Back to the colony") { dismiss() }.buttonStyle(RedButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ c: Crumb) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Pill(text: c.kind == .swarm ? "SWARM · torrent" : "CRUMB · normal link",
                         fg: c.kind == .swarm ? Theme.swarmText : Theme.crumbText,
                         bg: c.kind == .swarm ? Theme.swarmTint : Theme.crumbTint)
                    Text(c.name).font(Theme.display(30)).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if c.state == .paused {
                    Button("Wake the ants") { Task { await colony.resume(c) } }.buttonStyle(GhostButtonStyle(tint: Theme.red))
                } else {
                    Button("Let the ants rest") { Task { await colony.rest(c) } }.buttonStyle(GhostButtonStyle(tint: Theme.red))
                }
                Button("Show in Finder") { colony.reveal(c.homePath) }.buttonStyle(GhostButtonStyle())
                Button("Done") { dismiss() }.buttonStyle(RedButtonStyle()).keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 14) {
                    Card(radius: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            EveryFrame(active: c.isMoving, fps: 15) { now in
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Crumbs carried home · \(Fmt.liveSize(c.liveDone(now))) of \(c.total > 0 ? Fmt.liveSize(Double(c.total)) : "?")")
                                        .font(Theme.display(18)).monospacedDigit()
                                    Spacer()
                                    Text(String(format: "%.1f%%", c.liveProgress(now) * 100))
                                        .font(Theme.display(32)).monospacedDigit().foregroundStyle(Theme.swarmText)
                                }
                            }
                            if c.state == .paused {
                                HStack { Spacer(); AntSketch(pose: .rest).frame(height: 170); Spacer() }
                            } else {
                                Anthill(progress: c.progress).frame(maxHeight: 176)
                            }
                            HStack {
                                Text("The hill rises as pieces arrive. Dashed outline = the finished hill.")
                                Spacer()
                                Text("\(c.connections) ants on the trail").foregroundStyle(Theme.red).fontWeight(.semibold)
                            }
                            .font(Theme.body(13)).foregroundStyle(Theme.muted)
                        }
                    }
                    EveryFrame(active: c.isMoving, fps: 15) { now in
                        HStack(spacing: 12) {
                            mini("Coming home", Fmt.liveSpeed(c.liveDown(now)), honey: true)
                            mini("Sharing back", Fmt.speed(c.up))
                            mini(c.kind == .swarm ? "Ants helping" : "Ants pulling", c.kind == .swarm ? "\(c.connections) · \(c.seeders) full" : "\(c.connections)")
                            mini("Home in", c.state == .seeding ? "Home ✓" : Fmt.clock(c.liveEta(now)))
                        }
                    }
                    filesCard(c)
                }
                if c.kind == .swarm { peersCard }
            }
        }
        .padding(26)
    }

    private func mini(_ label: String, _ value: String, honey: Bool = false) -> some View {
        Card(radius: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.body(13)).foregroundStyle(Theme.muted)
                Text(value).font(Theme.display(22)).monospacedDigit().foregroundStyle(honey ? Theme.red : Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private func filesCard(_ c: Crumb) -> some View {
        Card(radius: 20) {
            VStack(alignment: .leading, spacing: 0) {
                Text("What's in it").font(Theme.display(18)).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(c.files) { f in
                            HStack(spacing: 12) {
                                Text(f.name.isEmpty ? c.name : f.name).font(Theme.body(14)).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(isPicked(f) ? Theme.text : Theme.muted)
                                Spacer()
                                Text(Fmt.bytes(f.length)).font(Theme.body(13)).foregroundStyle(Theme.muted)
                                if !c.isMetadata, isPicked(f), Streamer.isVideo(URL(fileURLWithPath: f.name)) {
                                    watchButton(f, c)
                                }
                                if c.kind == .swarm && c.files.count > 1 && !c.isMetadata {
                                    carryToggle(f, c)
                                }
                            }
                            .padding(.vertical, 7)
                            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .onAppear { if !picksLoaded { picks = Set(c.files.filter(\.selected).map(\.index)); picksLoaded = true } }
    }

    /// ▶ Watch now: plays the video while the rest of it downloads.
    private func watchButton(_ f: CrumbFile, _ c: Crumb) -> some View {
        let prep = colony.earlyPrep[c.gid]
        let label = prep.map { $0 >= 1 ? "▶ Playing" : "Getting ready \(Int($0 * 100))%" } ?? "▶ Watch now"
        return Button {
            Task { await colony.watchEarly(c, f) }
        } label: {
            Text(label).font(Theme.body(12, .semibold)).foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Theme.redFill))
        }
        .buttonStyle(.plain)
        .disabled(prep != nil && prep! < 1)
        .help("Starts playing in VLC once the opening has arrived. Torrents arrive in scattered pieces, so if you jump far ahead it may pause until the ants catch up.")
    }

    private func isPicked(_ f: CrumbFile) -> Bool { picksLoaded ? picks.contains(f.index) : f.selected }

    private func carryToggle(_ f: CrumbFile, _ c: Crumb) -> some View {
        HStack(spacing: 3) {
            seg("Carry it", on: isPicked(f)) { set(f, true, c) }
            seg("Leave it", on: !isPicked(f)) { set(f, false, c) }
        }
        .padding(3)
        .background(Capsule().fill(Theme.soil))
    }

    private func seg(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(Theme.body(12, .semibold))
                .foregroundStyle(on ? Theme.onAccent : Theme.muted)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(on ? Theme.redFill : .clear))
        }
        .buttonStyle(.plain)
    }

    private func set(_ f: CrumbFile, _ carry: Bool, _ c: Crumb) {
        if carry { picks.insert(f.index) } else { picks.remove(f.index) }
        if picks.isEmpty { picks.insert(f.index) } // always carry at least one file
        let now = picks
        Task { await colony.setFiles(c, selected: now) }
    }

    private var peersCard: some View {
        Card(radius: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ants from other colonies").font(Theme.display(18))
                Text("People sharing this with you right now").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    .padding(.bottom, 6)
                if peers.isEmpty {
                    Text("Looking for them…").font(Theme.body(14)).foregroundStyle(Theme.muted)
                }
                let top = max(peers.first?.down ?? 1, 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(peers.prefix(30)) { p in
                            VStack(spacing: 6) {
                                HStack(spacing: 10) {
                                    AntGlyph(color: Theme.swarmText).frame(width: 22)
                                    Text(maskIP(p.ip) + (p.seeder ? " · has it all" : "")).font(Theme.body(13))
                                    Spacer()
                                    Text(Fmt.speed(p.down)).font(Theme.body(13, .semibold))
                                }
                                Capsule().fill(Theme.soil).frame(height: 5)
                                    .overlay(alignment: .leading) {
                                        GeometryReader { g in
                                            Capsule().fill(Theme.swarm).frame(width: g.size.width * CGFloat(p.down) / CGFloat(top))
                                        }
                                    }
                            }
                            .padding(.vertical, 7)
                            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                        }
                    }
                }
                Spacer(minLength: 0)
                Text("Secret tunnels (encryption) on · Ants find each other on their own (DHT) on · \(doorText)")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
    }

    private func maskIP(_ ip: String) -> String {
        let parts = ip.split(separator: ".")
        if parts.count == 4 { return "\(parts[0]).\(parts[1]).•.•" }
        return ip.count > 12 ? String(ip.prefix(12)) + "…" : ip
    }

    private func loopPeers() async {
        while !Task.isCancelled {
            if let c = crumb { peers = await colony.peers(c) }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// Screen 2: Send the Ants — choose files from a .torrent before the swarm leaves.
struct SendSheet: View {
    let pending: PendingTorrent
    @State private var picks: Set<Int> = []
    @State private var dir: URL = Colony.shared.downloadDir
    @State private var startNow = true

    private var total: Int64 { pending.files.filter { picks.contains($0.index) }.reduce(0) { $0 + $1.length } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                ForEach(0..<9, id: \.self) { i in
                    AntGlyph(color: Theme.swarmText).frame(width: 28).opacity(1 - Double(i) * 0.1)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("The swarm's favourite: a torrent!").font(Theme.display(30))
                Text(pending.name).font(Theme.body(15)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("What to carry home").font(Theme.body(14, .semibold))
                    Spacer()
                    Text("\(Fmt.bytes(total)) total").font(Theme.body(14)).foregroundStyle(Theme.muted)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(pending.files) { f in
                            Toggle(isOn: Binding(get: { picks.contains(f.index) },
                                                 set: { on in if on { picks.insert(f.index) } else { picks.remove(f.index) } })) {
                                HStack {
                                    Text(f.name).font(Theme.body(14)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Fmt.bytes(f.length)).font(Theme.body(13)).foregroundStyle(Theme.muted)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .tint(Theme.red)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 12).fill(picks.contains(f.index) ? Theme.surface2 : .clear))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Store in chamber").font(Theme.body(14, .semibold))
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.directoryURL = dir
                        if panel.runModal() == .OK, let u = panel.url { dir = u }
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(dir.lastPathComponent).lineLimit(1)
                            Spacer()
                            Text("Change…").foregroundStyle(Theme.muted)
                        }
                        .font(Theme.body(14))
                        .padding(.horizontal, 12).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.soil))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("When").font(Theme.body(14, .semibold))
                    HStack(spacing: 3) {
                        whenButton("Right now", true)
                        whenButton("Let the ants rest first", false)
                    }
                    .padding(3)
                    .background(Capsule().fill(Theme.soil))
                    .overlay(Capsule().stroke(Theme.line))
                }
            }
            HStack {
                Text("Your ants share pieces back until you've given 1× what you took.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Never mind") { Task { await Colony.shared.cancel(pending) } }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Send the swarm") {
                    Task { await Colony.shared.confirm(pending, selected: picks, dir: dir, startNow: startNow) }
                }
                .buttonStyle(RedButtonStyle(big: true))
                .keyboardShortcut(.defaultAction)
                .disabled(picks.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 640)
        .background(Theme.surface)
        .foregroundStyle(Theme.text)
        .onAppear { picks = Set(pending.files.map(\.index)) }
    }

    private func whenButton(_ title: String, _ value: Bool) -> some View {
        Button { startNow = value } label: {
            Text(title).font(Theme.body(13, .semibold))
                .foregroundStyle(startNow == value ? Theme.onAccent : Theme.muted)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(startNow == value ? Theme.redFill : .clear))
        }
        .buttonStyle(.plain)
    }
}
