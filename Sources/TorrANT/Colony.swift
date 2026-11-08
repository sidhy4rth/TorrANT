import AppKit
import Observation
import UserNotifications

/// App state: talks to the engine, keeps the lists the screens show.
@MainActor @Observable
final class Colony {
    static let shared = Colony()

    var trail: [Crumb] = []          // downloading, waiting, resting, errors
    var seeding: [Crumb] = []        // feeding other colonies
    var hill: [HillItem] = []        // home: finished downloads
    var chatter: [Chatter] = []
    var down = 0
    var up = 0
    var antsOut = 0
    var prevDown = 0
    var prevUp = 0
    var speedAt = Date()
    var sessionBytes: Int64 = 0
    var online = false
    var problem: String?
    var spotted: String?
    var pending: PendingTorrent?
    var lastHome: HillItem?
    var openGID: String?

    var downloadDir: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "downloadDir") { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "downloadDir")
            Task { try? await aria.call("aria2.changeGlobalOption", [["dir": newValue.path]]) }
        }
    }

    /// Google Drive folder picked in Settings (nil = find it automatically).
    var driveDirPath: String? = UserDefaults.standard.string(forKey: "driveDir") {
        didSet { UserDefaults.standard.set(driveDirPath, forKey: "driveDir") }
    }
    var carrying: [UUID: String] = [:]   // on their way to Google Drive (id -> name)
    var unpacking: [UUID: String] = [:]  // .zip files being unpacked (id -> name)
    @ObservationIgnored private var unpackStat: [UUID: (done: Double, total: Double, at: Date, rate: Double)] = [:]

    /// Where "Move to Google Drive" puts things: the folder picked in Settings,
    /// or a TorrANT folder in the first Google Drive account on this Mac.
    var driveDir: URL? {
        if let p = driveDirPath { return URL(fileURLWithPath: p) }
        return Colony.findDrive()?.appendingPathComponent(Uploader.folder, isDirectory: true)
    }

    var watchClipboard: Bool {
        get { UserDefaults.standard.object(forKey: "watchClipboard") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "watchClipboard") }
    }

    @ObservationIgnored private let aria = Aria2()
    @ObservationIgnored private var booted = false
    @ObservationIgnored private var bootTime = Date()
    @ObservationIgnored private var lastState: [String: CrumbState] = [:]
    @ObservationIgnored private var lastSample: [String: Crumb] = [:]
    @ObservationIgnored private var homeLogged: Set<String> = []
    @ObservationIgnored private var lastClip = NSPasteboard.general.changeCount
    @ObservationIgnored private var seenClips: Set<String> = []
    @ObservationIgnored private var swarms: [SavedSwarm] = []
    @ObservationIgnored private var swarmByGID: [String: String] = [:]   // gid -> saved .torrent path
    @ObservationIgnored private var restored = false

    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT", isDirectory: true)
    }

    // MARK: Boot

    func boot() {
        guard !booted else { return }
        booted = true
        bootTime = Date()
        loadHill()
        do {
            try aria.start(downloadDir: downloadDir, support: support)
            say("Colony waking up")
        } catch {
            problem = error.localizedDescription
            say("Couldn't wake the colony: \(error.localizedDescription)")
            return
        }
        Task { await pollForever() }
        Task { await watchClipboardForever() }
        Task { await watchDriveForever() }
    }

    func shutdown() {
        Awake.shared.release()
        aria.stop()
    }

    private func pollForever() async {
        while true {
            await refresh()
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Refresh

    func refresh() async {
        do {
            let keys = Crumb.rpcKeys
            let a = try await aria.call("aria2.tellActive", [keys]) as? [[String: Any]] ?? []
            let w = try await aria.call("aria2.tellWaiting", [0, 500, keys]) as? [[String: Any]] ?? []
            let s = try await aria.call("aria2.tellStopped", [0, 500, keys]) as? [[String: Any]] ?? []
            let g = try await aria.call("aria2.getGlobalStat") as? [String: Any] ?? [:]
            apply(all: (a + w + s).compactMap(Crumb.init))
            // Only touch observed values when they change, so an idle window
            // doesn't redraw four times a second.
            let newDown = Int(g["downloadSpeed"] as? String ?? "") ?? 0
            let newUp = Int(g["uploadSpeed"] as? String ?? "") ?? 0
            if newDown != down || newUp != up || down != prevDown || up != prevUp {
                prevDown = down; prevUp = up; speedAt = Date()
                down = newDown; up = newUp
            }
            if !online { say("Colony online"); online = true }
            if problem != nil { problem = nil }
            if !restored { restored = true; await restoreSwarms() }
        } catch {
            // The engine needs a moment to start listening.
            if Date().timeIntervalSince(bootTime) > 6 {
                online = false
                problem = aria.isRunning ? "The colony isn't answering." : "The download engine stopped."
            }
        }
    }

    private func apply(all: [Crumb]) {
        var newTrail: [Crumb] = []
        var newSeeding: [Crumb] = []
        var ants = 0

        for var c in all {
            if let old = lastSample[c.gid] {
                c.prevDown = old.down
                if c.done > old.done { sessionBytes += c.done - old.done }
            } else {
                c.prevDown = c.down
            }
            lastSample[c.gid] = c
            let before = lastState[c.gid]
            lastState[c.gid] = c.state
            if c.state == .removed { continue }
            if c.gid == pending?.gid { continue }   // still choosing files

            // Magnet metadata step finished: the real download takes over.
            if c.isMetadata && (c.state == .complete || !c.followedBy.isEmpty) {
                if before != nil && before != .complete { say("Swarm found the map for \(c.name)") }
                Task { try? await aria.call("aria2.removeDownloadResult", [c.gid]) }
                continue
            }

            if c.isHome, !homeLogged.contains(c.gid) {
                homeLogged.insert(c.gid)
                if before != nil || c.state == .seeding { bringHome(c) }
                forgetSwarm(gid: c.gid)
            }

            switch c.state {
            case .complete:
                Task { try? await aria.call("aria2.removeDownloadResult", [c.gid]) }
            case .seeding:
                newSeeding.append(c); ants += c.connections
            case .error:
                if before != nil && before != .error { say("Trouble with \(c.name): \(c.errorMessage ?? "unknown")") }
                newTrail.append(c)
            case .paused:
                if before == .active { say("Ants resting on \(c.name)") }
                newTrail.append(c)
            default:
                if before == nil && Date().timeIntervalSince(bootTime) > 3 {
                    say(c.kind == .swarm ? "Swarm sent for \(c.name)" : "Crumb grabbed: \(c.name)")
                }
                newTrail.append(c); ants += c.connections
            }
        }
        let order: [CrumbState: Int] = [.active: 0, .waiting: 1, .paused: 2, .error: 3]
        let sorted = newTrail.enumerated().sorted {
            let a = order[$0.element.state] ?? 9, b = order[$1.element.state] ?? 9
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        if sorted != trail { trail = sorted }
        if newSeeding != seeding { seeding = newSeeding }
        if ants != antsOut { antsOut = ants }

        let working = sorted.contains { $0.state == .active || $0.state == .waiting }
            || driveBusy || !carrying.isEmpty || !unpacking.isEmpty || !Uploader.shared.jobs.isEmpty
            || NightShift.shared.needsMacAwake
        if Awake.shared.update(working: working) {
            say(Awake.shared.holding ? "Keeping the Mac awake while the ants work" : "All quiet. The Mac can sleep again")
        }
    }

    private func bringHome(_ c: Crumb) {
        let item = HillItem(name: c.name, path: c.homePath, size: c.total, kind: c.kind, date: Date())
        hill.insert(item, at: 0)
        if hill.count > 200 { hill.removeLast(hill.count - 200) }
        lastHome = item
        saveHill()
        say("\(c.name) is home ✓")
        Notifier.shared.home(item)
        if Uploader.shared.straightToDrive, !item.path.lowercased().hasSuffix(".torrent") {
            Task { await autoSend(item) }
        }
    }

    /// Hands-free: stop sharing, unpack a zip, upload, delete the Mac copy.
    func autoSend(_ item: HillItem) async {
        guard Uploader.shared.ready else {
            say("\(item.name) is on this Mac. Sign in to Google on the Drive page to send it up")
            return
        }
        await stopSeeding(item.path)
        var item = item
        if Colony.isZip(item.path) {
            guard let unpacked = await unpack(item) else { return }
            item = unpacked
        }
        let local = URL(fileURLWithPath: item.path)
        guard await Uploader.shared.sendFile(local) else { return }
        if let i = hill.firstIndex(where: { $0.id == item.id }), let dir = driveDir {
            hill[i].path = dir.appendingPathComponent(local.lastPathComponent).path
            saveHill()
        }
    }

    // MARK: Actions

    /// Paste box / menu / clipboard: links, magnets, or .torrent paths. Returns false if nothing usable.
    @discardableResult
    func send(_ raw: String) async -> Bool {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var any = false
        for line in lines {
            seenClips.insert(line)
            if spotted == line { spotted = nil }
            if line.lowercased().hasSuffix(".torrent"), FileManager.default.fileExists(atPath: line) {
                await openTorrent(URL(fileURLWithPath: line)); any = true; continue
            }
            if let u = URL(string: line), u.isFileURL, u.pathExtension.lowercased() == "torrent" {
                await openTorrent(u); any = true; continue
            }
            guard Link.isMagnet(line) || Link.isWebLink(line) else { continue }
            // Zips stop on the Mac first: Drive can't stream what's inside a zip, so they're
            // downloaded, unpacked, uploaded and deleted (the hands-free path) instead.
            let ext = URL(string: line)?.pathExtension.lowercased() ?? ""
            if Uploader.shared.straightToDrive, Link.isWebLink(line), ext != "torrent", ext != "zip" {
                if await Uploader.shared.sendLink(line) { any = true; continue }
                // Not signed in yet: fall back to the Mac, then hands-free upload.
            }
            if Link.isWebLink(line), let u = URL(string: line), u.pathExtension.lowercased() == "torrent" {
                // Remote .torrent: aria2 follows it into a swarm automatically.
            }
            do {
                try await aria.call("aria2.addUri", [[line], [String: String]()])
                any = true
            } catch {
                say("Couldn't send the ants: \(error.localizedDescription)")
            }
        }
        if any { await refresh() }
        return any
    }

    /// A download caught in Brave by the TorrANT Catcher extension. Carries the
    /// site's cookies, referrer and user agent so signed-in downloads still work.
    /// Returns nil on success, or a short reason Brave should keep it.
    func catchFromBrowser(url raw: String, cookies: String, referrer: String,
                          userAgent: String, filename: String) async -> String? {
        guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(),
              ["http", "https", "ftp"].contains(scheme) else { return "not a web link" }
        boot()
        for _ in 0..<30 where !online { try? await Task.sleep(for: .milliseconds(200)) }
        guard online else { return "the colony isn't awake" }

        // These become HTTP headers, so no line breaks may sneak in.
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }
        var opts: [String: Any] = [:]
        if !cookies.isEmpty { opts["header"] = ["Cookie: \(clean(cookies))"] }
        if !referrer.isEmpty { opts["referer"] = clean(referrer) }
        if !userAgent.isEmpty { opts["user-agent"] = clean(userAgent) }
        let name = (filename as NSString).lastPathComponent
        if !name.isEmpty, !name.hasPrefix("."), !name.contains("/") { opts["out"] = name }

        do {
            try await aria.call("aria2.addUri", [[raw], opts])
        } catch {
            say("Couldn't take that from Brave: \(error.localizedDescription)")
            return error.localizedDescription
        }
        let shown = name.isEmpty ? (u.lastPathComponent.isEmpty ? (u.host ?? raw) : u.lastPathComponent) : name
        say("Caught \(shown) from Brave")
        if !NSApp.isActive { Notifier.shared.caught(shown) }
        Task { await refresh() }   // answer Brave first
        return nil
    }

    /// A local .torrent: add it resting, then ask which files to carry.
    func openTorrent(_ url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let folder = support.appendingPathComponent("torrents", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let saved = folder.appendingPathComponent(UUID().uuidString + ".torrent")
            try data.write(to: saved)
            let gid = try await aria.call("aria2.addTorrent", [data.base64EncodedString(), [String](), ["pause": "true"]]) as? String ?? ""
            swarmByGID[gid] = saved.path
            let raw = try await aria.call("aria2.getFiles", [gid]) as? [[String: Any]] ?? []
            let files = raw.compactMap { f -> CrumbFile? in
                guard let idx = Int(f["index"] as? String ?? "") else { return nil }
                return CrumbFile(index: idx, path: f["path"] as? String ?? "",
                                 length: Int64(f["length"] as? String ?? "") ?? 0, done: 0, selected: true)
            }
            let status = try await aria.call("aria2.tellStatus", [gid, ["bittorrent"]]) as? [String: Any]
            let name = ((status?["bittorrent"] as? [String: Any])?["info"] as? [String: Any])?["name"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            pending = PendingTorrent(gid: gid, name: name, files: files, saved: saved.path)
        } catch {
            say("That .torrent didn't work: \(error.localizedDescription)")
        }
    }

    func confirm(_ p: PendingTorrent, selected: Set<Int>, dir: URL, startNow: Bool) async {
        pending = nil
        let picks = selected.sorted().map(String.init).joined(separator: ",")
        var opts = ["dir": dir.path]
        if !picks.isEmpty && selected.count < p.files.count { opts["select-file"] = picks }
        do {
            try await aria.call("aria2.changeOption", [p.gid, opts])
            if startNow { try await aria.call("aria2.unpause", [p.gid]) }
            swarms.append(SavedSwarm(file: p.saved, dir: dir.path, select: opts["select-file"], paused: !startNow))
            saveSwarms()
        } catch {
            say("Couldn't send the swarm: \(error.localizedDescription)")
        }
        await refresh()
    }

    func cancel(_ p: PendingTorrent) async {
        pending = nil
        try? await aria.call("aria2.forceRemove", [p.gid])
        try? await Task.sleep(for: .milliseconds(300))
        try? await aria.call("aria2.removeDownloadResult", [p.gid])
        swarmByGID[p.gid] = nil
        try? FileManager.default.removeItem(atPath: p.saved)
    }

    func rest(_ c: Crumb) async {
        try? await aria.call("aria2.forcePause", [c.gid])
        updateSwarm(gid: c.gid) { $0.paused = true }
        await refresh()
    }

    func resume(_ c: Crumb) async {
        try? await aria.call("aria2.unpause", [c.gid])
        updateSwarm(gid: c.gid) { $0.paused = false }
        await refresh()
    }

    // MARK: Saved swarms (.torrent files survive restarts without cluttering Downloads)

    private var swarmsFile: URL { support.appendingPathComponent("swarms.json") }

    private func saveSwarms() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(swarms) { try? data.write(to: swarmsFile, options: .atomic) }
    }

    private func updateSwarm(gid: String, _ change: (inout SavedSwarm) -> Void) {
        guard let file = swarmByGID[gid], let i = swarms.firstIndex(where: { $0.file == file }) else { return }
        change(&swarms[i])
        saveSwarms()
    }

    private func forgetSwarm(gid: String) {
        guard let file = swarmByGID.removeValue(forKey: gid) else { return }
        swarms.removeAll { $0.file == file }
        saveSwarms()
        try? FileManager.default.removeItem(atPath: file)
    }

    private func restoreSwarms() async {
        guard let data = try? Data(contentsOf: swarmsFile),
              let saved = try? JSONDecoder().decode([SavedSwarm].self, from: data) else { return }
        swarms = saved.filter { FileManager.default.fileExists(atPath: $0.file) }
        for s in swarms {
            guard let torrent = try? Data(contentsOf: URL(fileURLWithPath: s.file)) else { continue }
            var opts = ["dir": s.dir, "pause": s.paused ? "true" : "false"]
            if let sel = s.select { opts["select-file"] = sel }
            if let gid = try? await aria.call("aria2.addTorrent", [torrent.base64EncodedString(), [String](), opts]) as? String {
                swarmByGID[gid] = s.file
            }
        }
        saveSwarms()
        if !swarms.isEmpty { say("Picked up \(swarms.count) swarm\(swarms.count == 1 ? "" : "s") where they left off") }
    }

    func retry(_ c: Crumb) async {
        guard let src = c.source else { return }
        try? await aria.call("aria2.removeDownloadResult", [c.gid])
        await send(src)
    }

    func restAll() async { try? await aria.call("aria2.forcePauseAll"); await refresh() }
    func wakeAll() async { try? await aria.call("aria2.unpauseAll"); await refresh() }

    func remove(_ c: Crumb, deleteFiles: Bool) async {
        let path = c.homePath
        if c.state == .error || c.state == .complete {
            try? await aria.call("aria2.removeDownloadResult", [c.gid])
        } else {
            try? await aria.call("aria2.forceRemove", [c.gid])
            try? await Task.sleep(for: .milliseconds(400))
            try? await aria.call("aria2.removeDownloadResult", [c.gid])
        }
        forgetSwarm(gid: c.gid)
        if deleteFiles {
            let urls = [URL(fileURLWithPath: path), URL(fileURLWithPath: path + ".aria2")]
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { _ = try? await NSWorkspace.shared.recycle(urls) }
        }
        say("Dropped \(c.name)")
        await refresh()
    }

    /// Pick which files of a torrent to carry. aria2 only allows this while resting.
    func setFiles(_ c: Crumb, selected: Set<Int>) async {
        let wasRunning = c.state == .active || c.state == .seeding
        if wasRunning {
            try? await aria.call("aria2.forcePause", [c.gid])
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150))
                let st = try? await aria.call("aria2.tellStatus", [c.gid, ["status"]]) as? [String: Any]
                if (st?["status"] as? String) == "paused" { break }
            }
        }
        let picks = selected.sorted().map(String.init).joined(separator: ",")
        try? await aria.call("aria2.changeOption", [c.gid, ["select-file": picks]])
        if wasRunning { try? await aria.call("aria2.unpause", [c.gid]) }
        updateSwarm(gid: c.gid) { $0.select = picks }
        await refresh()
    }

    func peers(_ c: Crumb) async -> [Peer] {
        guard c.kind == .swarm,
              let raw = try? await aria.call("aria2.getPeers", [c.gid]) as? [[String: Any]] else { return [] }
        return raw.map { p in
            let ip = p["ip"] as? String ?? "?"
            return Peer(id: (p["peerId"] as? String ?? "") + ip + (p["port"] as? String ?? ""),
                        ip: ip,
                        down: Int(p["downloadSpeed"] as? String ?? "") ?? 0,
                        up: Int(p["uploadSpeed"] as? String ?? "") ?? 0,
                        seeder: (p["seeder"] as? String) == "true")
        }.sorted { $0.down > $1.down }
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func open(_ item: HillItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
    }

    func forget(_ item: HillItem) {
        hill.removeAll { $0.id == item.id }
        saveHill()
    }

    // MARK: Google Drive

    /// "My Drive" of the first Google Drive for desktop account, if it's installed.
    static func findDrive() -> URL? {
        let fm = FileManager.default
        let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: cloud.path)) ?? []
        for n in names.sorted() where n.hasPrefix("GoogleDrive-") {
            let my = cloud.appendingPathComponent(n).appendingPathComponent("My Drive", isDirectory: true)
            if fm.fileExists(atPath: my.path) { return my }
        }
        return nil
    }

    func isOnDrive(_ item: HillItem) -> Bool {
        if let d = driveDir, item.path.hasPrefix(d.path + "/") { return true }
        return item.path.contains("/Library/CloudStorage/GoogleDrive-")
    }

    /// Moves a finished download into Google Drive, then points the Anthill at its new home.
    func moveToDrive(_ item: HillItem) async {
        guard carrying[item.id] == nil, unpacking[item.id] == nil, !isOnDrive(item) else { return }
        guard driveDir != nil else { say(Colony.noDriveNote); return }
        await stopSeeding(item.path)
        // A .zip can't be streamed from Drive, so send the episodes instead.
        var item = item
        if Colony.isZip(item.path) {
            guard let unpacked = await unpack(item) else { return }
            item = unpacked
        }
        if let target = await carry(URL(fileURLWithPath: item.path), name: item.name, id: item.id),
           let i = hill.firstIndex(where: { $0.id == item.id }) {
            hill[i].path = target.path
            saveHill()
        }
    }

    /// A torrent still feeding others has its files open, so stop seeding first.
    private func stopSeeding(_ path: String) async {
        guard let c = seeding.first(where: { $0.homePath == path }) else { return }
        try? await aria.call("aria2.forceRemove", [c.gid])
        try? await Task.sleep(for: .milliseconds(400))
        try? await aria.call("aria2.removeDownloadResult", [c.gid])
        forgetSwarm(gid: c.gid)
        await refresh()
    }

    /// True while something in the Drive folder hasn't finished uploading.
    /// Checked every few seconds, so keep-awake covers Drive uploads too.
    @ObservationIgnored private var driveBusy = false

    private func watchDriveForever() async {
        while true {
            if let dir = driveDir {
                driveBusy = await Task.detached(priority: .utility) { Colony.anythingUploading(dir) }.value
            } else {
                driveBusy = false
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    nonisolated static func anythingUploading(_ dir: URL) -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .ubiquitousItemIsUploadedKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return false }
        var seen = 0
        for case let u as URL in e {
            seen += 1
            if seen > 5000 { break }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            if v.ubiquitousItemIsUploaded == false { return true }
        }
        return false
    }

    // MARK: Unpacking .zip downloads

    static func isZip(_ path: String) -> Bool { path.lowercased().hasSuffix(".zip") }

    /// Unpacks a finished .zip into a folder next to it, checks every byte came out,
    /// then bins the zip and points the Anthill at the folder.
    @discardableResult
    func unpack(_ item: HillItem) async -> HillItem? {
        guard Colony.isZip(item.path), unpacking[item.id] == nil else { return nil }
        await stopSeeding(item.path)
        guard let folder = await unpackZip(URL(fileURLWithPath: item.path), id: item.id, name: item.name) else { return nil }
        var updated = item
        updated.path = folder.path
        updated.name = folder.lastPathComponent
        if let i = hill.firstIndex(where: { $0.id == item.id }) {
            hill[i] = updated
            saveHill()
        }
        return updated
    }

    func liveUnpack(_ id: UUID, _ now: Date) -> Double {
        guard let u = unpackStat[id], u.total > 0 else { return 0 }
        let guess = u.done + u.rate * min(0.6, max(0, now.timeIntervalSince(u.at)))
        return ForwardOnly.shared.step("unpack:\(id)", toward: guess, atLeast: u.done, atMost: u.total) / u.total
    }

    private func unpackZip(_ zip: URL, id: UUID, name: String) async -> URL? {
        guard FileManager.default.fileExists(atPath: zip.path) else {
            say("Can't find \(name) any more")
            return nil
        }
        let parent = zip.deletingLastPathComponent()
        let base = zip.deletingPathExtension().lastPathComponent
        let temp = parent.appendingPathComponent(".\(base).unpacking", isDirectory: true)
        let total = await Task.detached { Colony.zipTotal(zip) }.value
        guard total > 0 else {
            say("\(name) doesn't look like a zip TorrANT can open")
            return nil
        }

        unpacking[id] = name
        unpackStat[id] = (0, Double(total), Date(), 0)
        ForwardOnly.shared.set("unpack:\(id)", 0)
        say("Unpacking \(name)…")

        // Watch the folder fill up so the bar moves while it unpacks.
        let watch = Task { @MainActor [weak self] in
            var last: (Date, Double)?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let done = Double(await Task.detached { Colony.folderBytes(temp) }.value)
                let now = Date()
                var rate = self?.unpackStat[id]?.rate ?? 0
                if let (t, d) = last, now.timeIntervalSince(t) > 0.1 {
                    rate = rate * 0.6 + max(0, (done - d) / now.timeIntervalSince(t)) * 0.4
                }
                last = (now, done)
                self?.unpackStat[id] = (done, Double(total), now, rate)
            }
        }

        let result: Result<URL, Error> = await Task.detached {
            do { return .success(try Colony.extract(zip, into: temp, base: base, expected: total)) }
            catch { return .failure(error) }
        }.value
        watch.cancel()
        unpacking[id] = nil
        unpackStat[id] = nil

        switch result {
        case .success(let folder):
            _ = try? await NSWorkspace.shared.recycle([zip])
            say("Unpacked \(folder.lastPathComponent) ✓ The zip is in the Trash")
            return folder
        case .failure(let e):
            try? FileManager.default.removeItem(at: temp)
            say("Couldn't unpack \(name): \(e.localizedDescription). The zip is untouched")
            return nil
        }
    }

    /// Bytes the zip holds once unpacked ("6 files, 4064516007 bytes uncompressed, …").
    nonisolated static func zipTotal(_ zip: URL) -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-t", zip.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: #"([0-9]+) bytes uncompressed"#, options: .regularExpression) else { return 0 }
        return Int64(text[r].split(separator: " ").first ?? "") ?? 0
    }

    nonisolated static func folderBytes(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var n: Int64 = 0
        for case let u as URL in e { n += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return n
    }

    struct UnpackError: LocalizedError {
        let errorDescription: String?
    }

    /// Unzips into a hidden folder, checks the size matches, then gives it its real name.
    /// A zip that already holds one folder isn't wrapped in a second one.
    nonisolated static func extract(_ zip: URL, into temp: URL, base: String, expected: Int64) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: temp)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, temp.path]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UnpackError(errorDescription: msg.isEmpty ? "unzip failed" : msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? fm.removeItem(at: temp.appendingPathComponent("__MACOSX"))
        let got = folderBytes(temp)
        guard got >= expected else {
            throw UnpackError(errorDescription: "only \(Fmt.bytes(got)) of \(Fmt.bytes(expected)) came out")
        }

        let inside = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var source = temp
        var name = base
        if inside.count == 1, (try? inside[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            source = inside[0]
            name = inside[0].lastPathComponent
        }
        let parent = temp.deletingLastPathComponent()
        var target = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = parent.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1
        }
        try fm.moveItem(at: source, to: target)
        if source != temp { try? fm.removeItem(at: temp) }
        return target
    }

    /// Files picked or dropped on the Google Drive page.
    func sendToDrive(_ urls: [URL]) async {
        for u in urls {
            let path = u.standardizedFileURL.path
            if let item = hill.first(where: { $0.path == path }) {
                await moveToDrive(item)
            } else if trail.contains(where: { $0.homePath == path }) {
                say("\(u.lastPathComponent) is still downloading. Send it once it's home")
            } else if Colony.isZip(path) {
                let id = UUID()
                if let folder = await unpackZip(u, id: id, name: u.lastPathComponent) {
                    _ = await carry(folder, name: folder.lastPathComponent, id: id)
                }
            } else {
                _ = await carry(u, name: u.lastPathComponent, id: UUID())
            }
        }
    }

    /// Writes down what started each move to Drive (App Support/TorrANT/drive-moves.log).
    private func noteDriveMove(_ name: String) {
        let line = "\(Date()) \(name)\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n") + "\n\n"
        let url = support.appendingPathComponent("drive-moves.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static let noDriveNote = "Google Drive isn't on this Mac yet. Install Google Drive for desktop, or pick a folder in Settings"

    /// The actual move, done off the main thread. Renames on a clash instead of overwriting.
    private func carry(_ src: URL, name: String, id: UUID) async -> URL? {
        noteDriveMove(name)
        guard let dest = driveDir else { say(Colony.noDriveNote); return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            say("Can't find \(name) any more")
            return nil
        }
        let s = src.standardizedFileURL.path, d = dest.standardizedFileURL.path
        if s == d || d.hasPrefix(s + "/") || s.hasPrefix(d + "/") {
            say("\(name) is already in Google Drive")
            return nil
        }

        carrying[id] = name
        say("Carrying \(name) to Google Drive…")
        let result: Result<URL, Error> = await Task.detached {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: src.path, isDirectory: &isDir)
                let ext = isDir.boolValue ? "" : src.pathExtension
                let base = ext.isEmpty ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent
                var target = dest.appendingPathComponent(src.lastPathComponent)
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    target = dest.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                    n += 1
                }
                try fm.moveItem(at: src, to: target)
                return .success(target)
            } catch {
                return .failure(error)
            }
        }.value
        carrying[id] = nil

        switch result {
        case .success(let target):
            say("\(name) is in Google Drive ✓ Uploading now")
            return target
        case .failure(let e):
            say("Couldn't move \(name): \(e.localizedDescription)")
            return nil
        }
    }

    // MARK: Clipboard sniffer ("Crumb spotted!")

    private func watchClipboardForever() async {
        while true {
            try? await Task.sleep(for: .seconds(1))
            checkClipboard()
        }
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastClip else { return }
        lastClip = pb.changeCount
        guard watchClipboard,
              let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.count < 4000, !s.contains("\n"), !seenClips.contains(s), Link.looksLikeCrumb(s) else { return }
        seenClips.insert(s)
        spotted = s
        if !NSApp.isActive { Notifier.shared.spotted(s) }
    }

    func grabSpotted() async {
        guard let s = spotted else { return }
        spotted = nil
        await send(s)
    }

    // MARK: Chatter + history

    func say(_ text: String) {
        chatter.insert(Chatter(time: Date(), text: text), at: 0)
        if chatter.count > 50 { chatter.removeLast() }
    }

    private var hillFile: URL { support.appendingPathComponent("anthill.json") }

    private func loadHill() {
        guard let data = try? Data(contentsOf: hillFile),
              let items = try? JSONDecoder().decode([HillItem].self, from: data) else { return }
        hill = items
    }

    private func saveHill() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(hill) { try? data.write(to: hillFile, options: .atomic) }
    }
}

/// macOS notifications: "X is home!" and "Crumb spotted!" with a Grab action.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private var ready = false

    func setup() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let grab = UNNotificationAction(identifier: "grab", title: "Grab it", options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: "crumb", actions: [grab], intentIdentifiers: [])])
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        ready = true
    }

    func home(_ item: HillItem) {
        post(title: "\(item.name) is home!", body: "Taste-tested and stored in the anthill.", info: ["path": item.path])
    }

    func spotted(_ link: String) {
        post(title: "Crumb spotted!", body: "Your ants found a link lying around. Grab it?", info: ["link": link], category: "crumb")
    }

    func caught(_ name: String) {
        post(title: "Caught from Brave", body: "\(name): your ants are carrying it home.", info: [:])
    }

    private func post(title: String, body: String, info: [String: String], category: String? = nil) {
        guard ready else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = info
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let link = info["link"] as? String {
            if response.actionIdentifier == "grab" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                Task { @MainActor in await Colony.shared.send(link) }
            }
        } else if let path = info["path"] as? String {
            Task { @MainActor in Colony.shared.reveal(path) }
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }
}
