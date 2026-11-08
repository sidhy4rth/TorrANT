import SwiftUI
import AppKit
import FileProvider
import UniformTypeIdentifiers

/// One thing in the TorrANT folder on Google Drive (a file, or a folder added up).
struct DriveItem: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isFolder: Bool
    var size: Int64 = 0
    var sent: Int64 = 0          // bytes uploaded so far
    var uploaded = false
    var uploading = false
    var onMac: Int64 = 0         // bytes taking space on this Mac
    var problem: String?
    var date = Date.distantPast

    var fraction: Double { uploaded ? 1 : size > 0 ? min(1, Double(sent) / Double(size)) : 0 }
    var fullyOnMac: Bool { size == 0 || onMac >= size * 9 / 10 }
    var cloudOnly: Bool { onMac < min(size, 1_000_000) }
}

/// What a scan of one file reads from Google Drive (done off the main thread).
private struct FileStat: Sendable {
    let path: String
    let size: Int64
    let uploaded: Bool
    let uploading: Bool
    let onMac: Int64
    let problem: String?
}

private struct EntryStat: Sendable {
    let url: URL
    let isFolder: Bool
    let date: Date
    let files: [FileStat]
}

/// Watches the Drive folder while the page is open: upload progress, speed, what's on the Mac.
@MainActor @Observable
final class DriveWatcher {
    static let shared = DriveWatcher()

    var items: [DriveItem] = []
    var speed: Double = 0        // bytes per second going up
    var scanned = false
    var busy: Set<String> = []   // items being freed up or downloaded

    @ObservationIgnored private var progress: [String: Progress] = [:]   // file path -> live upload progress
    @ObservationIgnored private var subscribers: [String: Any] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastSent: [String: Int64] = [:]   // file path -> bytes up at the last scan
    @ObservationIgnored private var lastSentAt = Date()

    var account: String? {
        guard let dir = Colony.shared.driveDir else { return nil }
        return dir.pathComponents.first { $0.hasPrefix("GoogleDrive-") }.map { String($0.dropFirst("GoogleDrive-".count)) }
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalSent: Int64 { items.reduce(0) { $0 + ($1.uploaded ? $1.size : $1.sent) } }
    var waitingBytes: Int64 { totalSize - totalSent }
    var uploadedCount: Int { items.filter(\.uploaded).count }
    var onMacUploaded: Int64 { items.filter(\.uploaded).reduce(0) { $0 + $1.onMac } }
    var eta: TimeInterval? { speed > 50_000 && waitingBytes > 0 ? Double(waitingBytes) / speed : nil }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        for s in subscribers.values { Progress.removeSubscriber(s) }
        subscribers = [:]; progress = [:]
        lastSent = [:]; speed = 0
    }

    func scan() async {
        guard let dir = Colony.shared.driveDir else { items = []; scanned = true; return }
        let entries = await Task.detached(priority: .utility) { DriveWatcher.read(dir) }.value

        // Live progress only exists while a file is still going up.
        var live = Set<String>()
        for e in entries { for f in e.files where !f.uploaded { live.insert(f.path) } }
        for path in subscribers.keys where !live.contains(path) {
            if let s = subscribers.removeValue(forKey: path) { Progress.removeSubscriber(s) }
            progress[path] = nil
        }
        for path in live where subscribers[path] == nil { subscribe(path) }

        let next: [DriveItem] = entries.map { e in
            var it = DriveItem(url: e.url, name: e.url.lastPathComponent, isFolder: e.isFolder, date: e.date)
            it.uploaded = !e.files.isEmpty && e.files.allSatisfy(\.uploaded)
            for f in e.files {
                it.size += f.size
                it.onMac += f.onMac
                it.uploading = it.uploading || f.uploading
                if it.problem == nil { it.problem = f.problem }
                if f.uploaded {
                    it.sent += f.size
                } else if let p = progress[f.path], p.totalUnitCount > 0 {
                    it.sent += min(f.size, max(0, p.completedUnitCount))
                }
            }
            if e.files.isEmpty { it.uploaded = true }
            return it
        }
        .sorted { $0.uploaded == $1.uploaded ? $0.date > $1.date : !$0.uploaded }

        // Upload speed: only bytes that moved since the last scan, on files we were already
        // watching (a fresh progress feed starts mid-way and would look like a burst).
        var sentNow: [String: Int64] = [:]
        for e in entries {
            for f in e.files {
                if f.uploaded { sentNow[f.path] = f.size }
                else if let p = progress[f.path], p.totalUnitCount > 0 { sentNow[f.path] = min(f.size, max(0, p.completedUnitCount)) }
            }
        }
        let now = Date()
        let dt = now.timeIntervalSince(lastSentAt)
        if !lastSent.isEmpty, dt > 0.2 {
            var delta: Int64 = 0
            for (path, b) in sentNow { if let a = lastSent[path] { delta += max(0, b - a) } }
            let rate = Double(delta) / dt
            speed = speed == 0 ? rate : speed * 0.7 + rate * 0.3
        }
        lastSent = sentNow; lastSentAt = now
        if !next.contains(where: { !$0.uploaded }) { speed = 0 }

        if next != items { items = next }
        scanned = true
    }

    private func subscribe(_ path: String) {
        let url = URL(fileURLWithPath: path)
        subscribers[path] = Progress.addSubscriber(forFileURL: url) { p in
            Task { @MainActor in DriveWatcher.shared.progress[path] = p }
            return {
                Task { @MainActor in
                    if DriveWatcher.shared.progress[path] === p { DriveWatcher.shared.progress[path] = nil }
                }
            }
        }
    }

    nonisolated private static func read(_ dir: URL) -> [EntryStat] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                                      .ubiquitousItemUploadingErrorKey, .contentModificationDateKey, .addedToDirectoryDateKey]
        guard let top = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }

        func stat(_ u: URL) -> FileStat? {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { return nil }
            return FileStat(path: u.path, size: Int64(v.fileSize ?? 0),
                            uploaded: v.ubiquitousItemIsUploaded ?? false,
                            uploading: v.ubiquitousItemIsUploading ?? false,
                            onMac: Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0),
                            problem: DriveWatcher.describe(v.ubiquitousItemUploadingError))
        }

        return top.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let date = v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast
            if v?.isDirectory == true {
                var files: [FileStat] = []
                let walker = fm.enumerator(at: u, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                while let f = walker?.nextObject() as? URL, files.count < 3000 {
                    if let s = stat(f) { files.append(s) }
                }
                return EntryStat(url: u, isFolder: true, date: date, files: files)
            }
            guard let s = stat(u) else { return nil }
            return EntryStat(url: u, isFolder: false, date: date, files: [s])
        }
    }

    /// Drive reports "can't reach the server" both when offline and when syncing is paused.
    nonisolated static func describe(_ e: Error?) -> String? {
        guard let e = e as NSError? else { return nil }
        if e.domain == NSFileProviderErrorDomain && e.code == -1004 { return "paused" }
        return e.localizedDescription
    }

    // MARK: Actions

    /// Keeps the file in Drive but removes the copy on this Mac (it streams when played).
    func freeUp(_ list: [DriveItem]) async {
        let ready = list.filter { $0.uploaded && !$0.cloudOnly && !busy.contains($0.id) }
        guard !ready.isEmpty else { return }
        for it in ready { busy.insert(it.id) }
        let urls = ready.map(\.url)
        let failed: [String] = await Task.detached {
            var bad: [String] = []
            for u in urls {
                do { try FileManager.default.evictUbiquitousItem(at: u) } catch { bad.append(u.lastPathComponent) }
            }
            return bad
        }.value
        // Drive frees the space in the background; measure what actually went.
        let ids = Set(ready.map(\.id))
        let before = ready.reduce(0) { $0 + $1.onMac }
        var after = before
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await scan()
            after = items.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.onMac }
            if after < before / 10 { break }
        }
        for it in ready { busy.remove(it.id) }
        if !failed.isEmpty {
            Colony.shared.say("Couldn't free up \(failed.joined(separator: ", "))")
        } else if before - after > 0 {
            Colony.shared.say("Freed \(Fmt.bytes(before - after)) on this Mac. Still in Google Drive ✓")
        } else {
            Colony.shared.say("Google Drive is busy. Try Free up space again in a minute")
        }
    }

    /// Pulls a cloud-only item back onto the Mac so it plays without internet.
    func download(_ it: DriveItem) async {
        guard !busy.contains(it.id) else { return }
        busy.insert(it.id)
        let url = it.url, folder = it.isFolder
        let ok: Bool = await Task.detached {
            let fm = FileManager.default
            var targets = [url]
            if folder {
                targets = (fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                    .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }) ?? []
            }
            var ok = true
            for t in targets { if (try? fm.startDownloadingUbiquitousItem(at: t)) == nil { ok = false } }
            return ok
        }.value
        busy.remove(it.id)
        Colony.shared.say(ok ? "Bringing \(it.name) back to this Mac for offline watching" : "Couldn't download \(it.name)")
    }
}

// MARK: - The page

struct DriveView: View {
    @State private var watcher = DriveWatcher.shared
    @State private var dropTargeted = false
    private var colony: Colony { Colony.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            if colony.driveDir == nil {
                noDrive
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    dropBar
                    stats
                    HStack(alignment: .firstTextBaseline) {
                        Text("In your Drive").font(Theme.display(22))
                        Text("TorrANT folder").font(Theme.body(14)).foregroundStyle(Theme.muted)
                        Spacer()
                        legend(Theme.red, "Uploading")
                        legend(Theme.safe, "In Drive")
                    }
                    list
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(SoilBackground().ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.red, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .onAppear { watcher.start() }
        .onDisappear { watcher.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "icloud.and.arrow.up.fill").font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.red)
            Text("Google Drive").font(Theme.display(24))
            Text("Winged ants fly your files up.").font(Theme.body(14)).foregroundStyle(Theme.muted)
            Spacer()
            if let a = watcher.account {
                HStack(spacing: 8) {
                    Circle().fill(Theme.safe).frame(width: 8, height: 8)
                    Text(a).font(Theme.body(14)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            if let dir = colony.driveDir {
                Button("Open in Finder") { NSWorkspace.shared.open(dir) }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.leading, 86)
        .padding(.trailing, 18)
        .frame(height: 54)
        .background(Theme.deep)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.surface2).frame(height: 1) }
    }

    private var dropBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.doc").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop movies, shows or any files here").font(Theme.display(17))
                Text("They're moved into Google Drive, not copied, so they stop filling up this Mac.")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Choose files…", action: pickFiles)
                .buttonStyle(RedButtonStyle(big: true))
                .keyboardShortcut("o", modifiers: [.command])
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.lineSoft, style: StrokeStyle(lineWidth: 2, dash: [7, 6])))
    }

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Flying up").font(Theme.body(14)).foregroundStyle(Theme.muted)
                    let (n, u) = Fmt.speedParts(Int(watcher.speed))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(n).font(Theme.display(38)).foregroundStyle(Theme.red).monospacedDigit()
                        Text(u).font(Theme.body(15, .semibold)).foregroundStyle(Theme.muted)
                    }
                    .frame(height: 46, alignment: .leading)
                    Text(watcher.waitingBytes > 0
                         ? "\(Fmt.bytes(watcher.waitingBytes)) to go · \(Fmt.eta(watcher.eta)) left"
                         : "Nothing waiting")
                        .font(Theme.body(13)).foregroundStyle(Theme.muted).monospacedDigit()
                        .frame(height: 36, alignment: .leading)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safe in Drive").font(Theme.body(14)).foregroundStyle(Theme.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(watcher.uploadedCount)").font(Theme.display(38)).monospacedDigit()
                        Text("of \(watcher.items.count)").font(Theme.body(15, .semibold)).foregroundStyle(Theme.muted)
                    }
                    .frame(height: 46, alignment: .leading)
                    Bar(fraction: watcher.totalSize > 0 ? Double(watcher.totalSent) / Double(watcher.totalSize) : 0,
                        color: watcher.waitingBytes > 0 ? Theme.red : Theme.safe)
                        .frame(height: 6)
                        .frame(height: 36)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Uploaded but still on this Mac").font(Theme.body(14)).foregroundStyle(Theme.muted)
                    Text(watcher.onMacUploaded > 0 ? Fmt.bytes(watcher.onMacUploaded) : "0 GB")
                        .font(Theme.display(38)).monospacedDigit()
                        .frame(height: 46, alignment: .leading)
                    let freeable = watcher.items.filter { $0.uploaded && !$0.cloudOnly }
                    Button("Free up space") { Task { await watcher.freeUp(freeable) } }
                        .buttonStyle(GhostButtonStyle(tint: freeable.isEmpty ? Theme.text : Theme.safe))
                        .disabled(freeable.isEmpty)
                        .opacity(freeable.isEmpty ? 0.4 : 1)
                        .help("Removes the Mac copy of everything already uploaded. It stays in Drive and streams when you play it.")
                }
            }
        }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        let moving = colony.carrying.sorted { $0.value < $1.value }
        if watcher.items.isEmpty && moving.isEmpty {
            VStack(spacing: 14) {
                AntSketch(pose: .rest).frame(width: 260)
                Text(watcher.scanned ? "Nothing up here yet." : "Looking in your Drive…").font(Theme.display(24))
                Text("Drop files above, or press the cloud on a finished download in the Anthill.")
                    .font(Theme.body(15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(moving, id: \.key) { m in MovingRow(name: m.value) }
                    ForEach(watcher.items) { it in DriveRow(item: it) }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }

    private var noDrive: some View {
        VStack(spacing: 14) {
            AntSketch(pose: .alert).frame(width: 260)
            Text("Google Drive isn't set up.").font(Theme.display(24))
            Text("Install Google Drive for desktop and sign in, then come back.\nOr pick any folder in Settings.")
                .font(Theme.body(15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            SettingsLink { Text("Open Settings") }.buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 10, height: 10)
            Text(t).font(Theme.body(14)).foregroundStyle(Theme.muted)
        }
        .padding(.leading, 12)
    }

    // MARK: Adding files

    private func pickFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = "Move to Drive"
        p.message = "Pick files or folders to move into Google Drive"
        p.directoryURL = colony.downloadDir
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let urls = p.urls
        Task { await colony.sendToDrive(urls); await watcher.scan() }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    await Colony.shared.sendToDrive([url])
                    await DriveWatcher.shared.scan()
                }
            }
        }
        return true
    }
}

// MARK: - Rows

struct DriveRow: View {
    let item: DriveItem
    @State private var hover = false
    private var watcher: DriveWatcher { DriveWatcher.shared }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.isFolder ? "folder.fill" : "film")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(item.uploaded ? Theme.safe : Theme.red)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.surface2))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(item.name).font(Theme.body(15, .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(statusText).font(Theme.body(13, .semibold)).foregroundStyle(statusColor).monospacedDigit()
                }
                Bar(fraction: item.fraction, color: item.uploaded ? Theme.safe : Theme.red).frame(height: 6)
                HStack(spacing: 8) {
                    Text(item.uploaded ? Fmt.bytes(item.size)
                         : "\(Fmt.bytes(item.sent)) of \(Fmt.bytes(item.size))")
                        .monospacedDigit()
                    Text("·")
                    Text(placeText)
                }
                .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(hover ? Theme.surface2 : Theme.surface))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .help(item.problem == "paused" ? "Google Drive can't upload right now. Syncing is paused or there's no internet."
              : item.problem ?? "Double-click to play")
        .contextMenu { menu }
    }

    private var statusText: String {
        if watcher.busy.contains(item.id) { return "Working…" }
        if item.problem == "paused" { return "Drive paused or offline" }
        if item.problem != nil { return "Upload problem" }
        if item.uploaded { return "In Drive ✓" }
        if item.uploading || item.sent > 0 { return "\(Int(item.fraction * 100))%" }
        return "Waiting in line"
    }

    private var statusColor: Color {
        if item.problem == "paused" { return Theme.muted }
        if item.problem != nil { return Theme.poison }
        return item.uploaded ? Theme.safe : item.uploading ? Theme.red : Theme.muted
    }

    private var placeText: String {
        if item.cloudOnly { return "Cloud only, streams when played" }
        if item.fullyOnMac { return item.uploaded ? "Also on this Mac" : "On this Mac until it's up" }
        return "\(Fmt.bytes(item.onMac)) on this Mac"
    }

    private var controls: some View {
        HStack(spacing: 6) {
            iconButton("play.fill", "Play") { NSWorkspace.shared.open(item.url) }
            if item.uploaded && !item.cloudOnly {
                iconButton("externaldrive.badge.minus", "Free up space on this Mac") { Task { await watcher.freeUp([item]) } }
            } else if item.cloudOnly {
                iconButton("arrow.down.to.line", "Download to this Mac for offline") { Task { await watcher.download(item) } }
            }
            iconButton("magnifyingglass", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        .opacity(hover ? 1 : 0.35)
        .disabled(watcher.busy.contains(item.id))
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        Button("Play") { NSWorkspace.shared.open(item.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        if item.uploaded && !item.cloudOnly {
            Button("Free up space on this Mac") { Task { await watcher.freeUp([item]) } }
        }
        if !item.fullyOnMac {
            Button("Download to this Mac for offline") { Task { await watcher.download(item) } }
        }
    }
}

private struct MovingRow: View {
    let name: String
    var body: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(Theme.body(15, .semibold)).lineLimit(1).truncationMode(.middle)
                Text("Moving into Google Drive…").font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
    }
}

/// Thin progress bar.
struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface2)
                Capsule().fill(color).frame(width: max(fraction > 0 ? 6 : 0, g.size.width * fraction))
            }
        }
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
