import SwiftUI
import UniformTypeIdentifiers

/// Screen 1: The Colony.
struct ColonyView: View {
    @Bindable private var colony = Colony.shared
    @Environment(\.openWindow) private var openWindow
    @State private var input = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                main
                sidebar
            }
        }
        .background(SoilBackground().ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.red, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .sheet(item: $colony.pending) { p in SendSheet(pending: p) }
        .sheet(isPresented: Binding(get: { colony.openGID != nil }, set: { if !$0 { colony.openGID = nil } })) {
            if let gid = colony.openGID { SwarmView(gid: gid) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            AntGlyph(color: Theme.red).frame(width: 32)
            (Text("Torr") + Text("ANT").foregroundColor(Theme.red))
                .font(Theme.display(24))
            Text("No crumb too big.").font(Theme.body(14)).foregroundStyle(Theme.muted)
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(colony.online ? Theme.safe : Theme.swarm).frame(width: 8, height: 8)
                Text(colony.online ? "Colony online · \(colony.antsOut) ants out" : (colony.problem ?? "Waking the colony…"))
                    .font(Theme.body(14)).foregroundStyle(Theme.muted)
            }
            DriveModeSwitch()
            Button { openWindow(id: "library") } label: {
                HStack(spacing: 7) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 14, weight: .semibold))
                    Text("Library").font(Theme.body(14, .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            }
            .buttonStyle(.plain)
            .help("Your movies and shows in Drive (⇧⌘L)")
            Button { openWindow(id: "drive") } label: {
                HStack(spacing: 7) {
                    Image(systemName: colony.carrying.isEmpty ? "icloud.and.arrow.up" : "icloud.and.arrow.up.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Google Drive").font(Theme.body(14, .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            }
            .buttonStyle(.plain)
            .help("Uploads to Google Drive (⇧⌘D)")
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.leading, 86)
        .padding(.trailing, 18)
        .frame(height: 54)
        .background(Theme.deep)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.surface2).frame(height: 1) }
    }

    // MARK: Main column

    private var main: some View {
        VStack(alignment: .leading, spacing: 16) {
            addBar
            if let s = colony.spotted { SpottedBanner(link: s) }
            HStack(spacing: 14) {
                odoStat("Coming home", color: Theme.red) { Fmt.odoSpeed(Colony.shared.liveDown($0)) }
                odoStat("Sharing with other colonies", color: Theme.text) { Fmt.odoSpeed(Colony.shared.liveUp($0)) }
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Carried home this session").font(Theme.body(14)).foregroundStyle(Theme.muted)
                        LiveLabel(live: colony.anythingMoving, font: LiveFont.display(38), color: Theme.text) {
                            Fmt.liveSize(Colony.shared.liveSession($0))
                        }
                        .frame(height: 46)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("On the trail").font(Theme.display(22))
                Spacer()
                legend(Theme.swarm, "Swarm = torrent")
                legend(Theme.crumb, "Crumb = normal link")
            }
            if colony.trail.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(colony.trail) { c in TrailRow(c: c) }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var addBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop a torrent, magnet or link").font(Theme.display(17))
                TextField("", text: $input, prompt: Text("The ants will take it from here…").foregroundColor(Theme.muted))
                    .textFieldStyle(.plain)
                    .font(Theme.body(14))
                    .onSubmit(sendInput)
            }
            Button { openWindow(id: "grabber") } label: {
                Image(systemName: "link.badge.plus").font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help("Link Grabber & Night shift (⇧⌘G)")
            Button {
                openTorrentPanel()
            } label: {
                Image(systemName: "doc.badge.plus").font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help("Open a .torrent file")
            Button("Send the ants", action: sendInput)
                .buttonStyle(RedButtonStyle(big: true))
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.lineSoft, style: StrokeStyle(lineWidth: 2, dash: [7, 6])))
    }

    private func odoStat(_ label: String, color: Color, _ value: @escaping (Date) -> (Double, String)) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(Theme.body(14)).foregroundStyle(Theme.muted)
                OdometerLayer(live: colony.anythingMoving, size: 38, color: color, value: value)
                    .frame(height: 46)
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 10, height: 10)
            Text(t).font(Theme.body(14)).foregroundStyle(Theme.muted)
        }
        .padding(.leading, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            AntSketch(pose: .walk).frame(width: 300)
            Text("No crumbs yet.").font(Theme.display(24))
            Text("Paste a link or magnet above, drop a .torrent anywhere,\nor copy a download link and your ants will notice.")
                .font(Theme.body(15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The Anthill").font(Theme.display(22))
            Text("Everything the ants brought home.").font(Theme.body(14)).foregroundStyle(Theme.muted)
                .padding(.top, -8)
            if colony.hill.isEmpty {
                Text("Empty for now. Finished downloads land here.")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface2))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(colony.hill) { h in HillRow(item: h) }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 300)
            }
            if !colony.seeding.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Feeding other colonies").font(Theme.body(15, .bold))
                    ForEach(colony.seeding) { c in
                        HStack {
                            Text(c.name).font(Theme.body(14)).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f× shared", c.ratio)).font(Theme.body(14, .semibold)).foregroundStyle(Theme.swarmText)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { colony.openGID = c.gid }
                        .contextMenu {
                            Button("Stop sharing") { Task { await colony.remove(c, deleteFiles: false) } }
                            Button("Show in Finder") { colony.reveal(c.homePath) }
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface2))
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text("Colony chatter").font(Theme.body(14, .bold)).foregroundStyle(Theme.red)
                ForEach(colony.chatter.prefix(4)) { m in
                    Text("\(Fmt.clock(m.time)) · \(m.text)").font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
        }
        .padding(20)
        .frame(width: 330)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.surface2).frame(width: 1) }
    }

    // MARK: Actions

    private func sendInput() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        input = ""
        Task {
            if !(await colony.send(text)) {
                colony.say("That doesn't look like a link, magnet or .torrent")
                input = text
            }
        }
    }

    private func openTorrentPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            Task { for u in panel.urls { await colony.openTorrent(u) } }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if url.isFileURL { await Colony.shared.openTorrent(url) } else { await Colony.shared.send(url.absoluteString) }
                    }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s else { return }
                    Task { @MainActor in await Colony.shared.send(s) }
                }
            }
        }
        return true
    }
}

// MARK: - Rows

struct TrailRow: View {
    let c: Crumb
    @State private var hover = false
    private var colony: Colony { Colony.shared }

    private var look: (pill: String, fg: Color, bg: Color, bar: Color, ant: Color) {
        switch c.state {
        case .paused: return ("RESTING", Theme.muted, Color(hex: 0x222222), Theme.rest, Color(hex: 0x7A7470))
        case .error: return ("STUCK", Color(hex: 0xD9BDFF), Color(hex: 0x2E2236), Theme.poison, Color(hex: 0xD9BDFF))
        default:
            return c.kind == .swarm
                ? ("SWARM", Theme.swarmText, Theme.swarmTint, Theme.swarm, Theme.swarmText)
                : ("CRUMB", Theme.crumbText, Theme.crumbTint, Theme.crumb, Color.white)
        }
    }

    private func meta(_ now: Date) -> String {
        if c.isMetadata { return "Finding the swarm…" }
        let total = c.total > 0 ? Fmt.liveSize(Double(c.total)) : "size unknown"
        let ants = c.kind == .swarm ? "\(c.connections) ants" : "\(c.connections) ants pulling"
        switch c.state {
        case .paused: return "Ants resting · \(Fmt.liveSize(Double(c.done))) of \(total)"
        case .waiting: return "Waiting in line · \(total)"
        case .error: return c.errorMessage ?? "Something went wrong"
        default: return "\(ants) · \(Fmt.liveSize(c.liveDone(now))) of \(total)"
        }
    }

    private func etaText(_ now: Date) -> String {
        switch c.state {
        case .paused: return "zzz"
        case .error: return "!"
        case .waiting: return "—"
        default: return Fmt.clock(c.liveEta(now))
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Pill(text: look.pill, fg: look.fg, bg: look.bg).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(c.name).font(Theme.body(15, .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    LiveLabel(live: c.isMoving, font: LiveFont.body(14), color: Theme.muted, align: .right) { meta($0) }
                        .frame(width: 300, height: 20)
                }
                LiveBarLayer(live: c.isMoving, color: look.bar, ant: look.ant) { c.liveProgress($0) }
                    .frame(height: 18)
            }
            VStack(alignment: .trailing, spacing: 2) {
                LiveLabel(live: c.isMoving, font: LiveFont.display(21), color: Theme.text, align: .right) { etaText($0) }
                    .frame(height: 26)
                LiveLabel(live: c.isMoving, font: LiveFont.body(13, 600), color: c.state == .active ? look.fg : Theme.muted, align: .right) {
                    c.state == .active ? Fmt.liveSpeed(c.liveDown($0)) : (c.state == .paused ? "paused" : " ")
                }
                .frame(height: 18)
            }
            .frame(width: 104)
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hover ? Theme.surface2 : Theme.surface))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { colony.openGID = c.gid }
        .contextMenu { menu }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if c.state == .paused || c.state == .waiting {
                iconButton("play.fill", "Wake the ants") { await colony.resume(c) }
            } else if c.state == .error {
                iconButton("arrow.clockwise", "Try again") { await colony.retry(c) }
            } else {
                iconButton("pause.fill", "Let the ants rest") { await colony.rest(c) }
            }
            iconButton("xmark", "Drop it") { await colony.remove(c, deleteFiles: false) }
        }
        .opacity(hover ? 1 : 0.35)
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.surface2))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private var menu: some View {
        Button("Open details") { colony.openGID = c.gid }
        if c.state == .paused { Button("Wake the ants") { Task { await colony.resume(c) } } }
        else { Button("Let the ants rest") { Task { await colony.rest(c) } } }
        Button("Show in Finder") { colony.reveal(c.homePath) }
        if let s = c.source {
            Button("Copy link") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
            }
        }
        Divider()
        Button("Drop it") { Task { await colony.remove(c, deleteFiles: false) } }
        Button("Drop it and bin the files") { Task { await colony.remove(c, deleteFiles: true) } }
    }
}

struct HillRow: View {
    let item: HillItem
    @State private var hover = false
    @State private var confirmDrive = false
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(item.kind == .swarm ? Theme.swarm : Theme.crumb).frame(width: 10, height: 10)
            Text(item.name).font(Theme.body(14, .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            driveBadge
            Text(Fmt.when(item.date)).font(Theme.body(12)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(hover ? Theme.line : Theme.surface2))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { Colony.shared.open(item) }
        .onTapGesture { Colony.shared.reveal(item.path) }
        .help("Click to show in Finder, double-click to open")
        .confirmationDialog("Move \(item.name) to Google Drive?", isPresented: $confirmDrive) {
            Button("Move to Google Drive") { Task { await Colony.shared.moveToDrive(item) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Colony.isZip(item.path)
                 ? "TorrANT unpacks it first so each episode streams on its own, and puts the zip in the Trash. This uploads \(Fmt.bytes(item.size)) using your internet data."
                 : "This uploads \(Fmt.bytes(item.size)) using your internet data.")
        }
        .contextMenu {
            Button("Open") { Colony.shared.open(item) }
            Button("Show in Finder") { Colony.shared.reveal(item.path) }
            if Colony.isZip(item.path) && Colony.shared.unpacking[item.id] == nil {
                Button("Unpack (zip goes to Trash)") { Task { await Colony.shared.unpack(item) } }
            }
            if !Colony.shared.isOnDrive(item) && Colony.shared.carrying[item.id] == nil {
                Button("Move to Google Drive…") { confirmDrive = true }
            }
            Divider()
            Button("Forget it") { Colony.shared.forget(item) }
        }
    }

    @ViewBuilder private var driveBadge: some View {
        let colony = Colony.shared
        if colony.unpacking[item.id] != nil {
            LiveLabel(live: true, font: LiveFont.body(12, 600), color: Theme.red, align: .right) { now in
                String(format: "Unpacking %.0f%%", colony.liveUnpack(item.id, now) * 100)
            }
            .frame(width: 110, height: 16)
        } else if colony.carrying[item.id] != nil {
            ProgressView().controlSize(.small)
                .help("Moving to Google Drive…")
                .accessibilityLabel("Moving to Google Drive")
        } else if colony.isOnDrive(item) {
            Image(systemName: "icloud.fill").font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .help("On Google Drive")
                .accessibilityLabel("On Google Drive")
        } else {
            Button { confirmDrive = true } label: {
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)   // hidden means not clickable
            .help("Move to Google Drive")
            .accessibilityLabel("Move to Google Drive")
        }
    }
}

/// The "slider": new downloads go to this Mac, or straight to Google Drive.
struct DriveModeSwitch: View {
    @State private var up = Uploader.shared
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: up.straightToDrive ? "icloud.fill" : "laptopcomputer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(up.straightToDrive ? Theme.safe : Theme.muted)
                .frame(width: 18)
            Text(up.straightToDrive ? "Straight to Drive" : "Save to this Mac")
                .font(Theme.body(13, .semibold))
                .foregroundStyle(up.straightToDrive ? Theme.safe : Theme.muted)
                .frame(width: 112, alignment: .leading)
            Toggle("", isOn: Binding(get: { up.straightToDrive },
                                     set: { v in withAnimation(.easeOut(duration: 0.18)) { up.straightToDrive = v } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .tint(Theme.safe)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(up.straightToDrive ? Theme.safe.opacity(0.5) : Theme.line))
        .help("Where new downloads go. Straight to Drive: links upload directly with nothing on this Mac; torrents upload and delete the Mac copy when they finish.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Straight to Google Drive")
        .accessibilityValue(up.straightToDrive ? "On" : "Off")
    }
}

/// "Crumb spotted!" — clipboard sniffer banner.
struct SpottedBanner: View {
    let link: String
    var body: some View {
        HStack(spacing: 14) {
            AntSketch(pose: .alert).frame(width: 96)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("Crumb spotted!").font(Theme.display(20))
                    Pill(text: Link.isMagnet(link) ? "SWARM" : "CRUMB",
                         fg: Link.isMagnet(link) ? Theme.swarmText : Theme.crumbText,
                         bg: Link.isMagnet(link) ? Theme.swarmTint : Theme.crumbTint)
                }
                Text("Your ants found a link lying around. Grab it?").font(Theme.body(14)).foregroundStyle(Theme.muted)
                Text(link).font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Leave it") { Colony.shared.spotted = nil }.buttonStyle(GhostButtonStyle())
            Button("Grab it") { Task { await Colony.shared.grabSpotted() } }.buttonStyle(RedButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.crumb, lineWidth: 2))
    }
}
