import AppKit
import Foundation

/// "Straight to Google Drive" mode. rclone's control server does the uploading into the
/// TorrANT Library folder, with the same sign-in streaming uses (read Drive, and create
/// or change only files TorrANT made).
///  · A plain link streams from the web straight into Drive: no Mac disk at all.
///  · A finished download on the Mac (torrents, Brave catches) is unpacked if it's a zip,
///    moved up, and the Mac copy deleted once Drive has it.
///  · With the switch on "Save to this Mac", sending something up copies it instead: Drive
///    gets it and the Mac copy stays (user, 15 Nov: films to watch offline tonight, backed up too).
@MainActor @Observable
final class Uploader {
    static let shared = Uploader()
    nonisolated static let folder = "TorrANT Library"

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let jobid: Int
        var name: String
        let straight: Bool          // link → Drive, nothing on the Mac
        var keep = false            // copy up, the Mac file stays
        var fs = "drive:"           // the drive it's going to (to check it arrived)
        var size: Double = 0
        var done: Double = 0
        var speed: Double = 0
        var at = Date()
    }

    var jobs: [Job] = []

    // MARK: Where uploads go

    /// A Google shared drive the Library also lives on (bought storage, 15 Nov), next to My Drive.
    struct SharedDrive: Codable, Equatable, Hashable { let id: String; let name: String }

    /// The shared drive in use, if any. Its "TorrANT Library" folder is read into the Library
    /// alongside My Drive's; nonisolated so streaming paths can be worked out off the main thread.
    nonisolated static var savedShared: SharedDrive? {
        guard let d = UserDefaults.standard.data(forKey: "sharedDrive") else { return nil }
        return try? JSONDecoder().decode(SharedDrive.self, from: d)
    }
    var sharedDrive: SharedDrive? = Uploader.savedShared {
        didSet {
            UserDefaults.standard.set(sharedDrive.flatMap { try? JSONEncoder().encode($0) }, forKey: "sharedDrive")
            if sharedDrive == nil { uploadToShared = false }
        }
    }
    /// True: new uploads go to the shared drive. False: My Drive.
    var uploadToShared: Bool = UserDefaults.standard.bool(forKey: "uploadToShared") {
        didSet { UserDefaults.standard.set(uploadToShared, forKey: "uploadToShared") }
    }
    /// Shared drives this Google account can use, for the picker on the Drive page.
    var sharedDrives: [SharedDrive] = []

    /// rclone's name for a drive: My Drive, or a shared drive by id.
    nonisolated static func fs(_ shared: SharedDrive?, chunk: Bool = false) -> String {
        var opts: [String] = []
        if chunk { opts.append("chunk_size=32M") }
        if let shared { opts.append("team_drive=\(shared.id)") }
        return opts.isEmpty ? "drive:" : "drive," + opts.joined(separator: ",") + ":"
    }
    /// Where new uploads land.
    var target: SharedDrive? { uploadToShared ? sharedDrive : nil }
    var targetName: String { target?.name ?? "My Drive" }

    func loadSharedDrives() async {
        guard ready, await ensureDaemon(),
              let r = await call("backend/command", ["command": "drives", "fs": "drive:"], timeout: 20),
              let list = r["result"] as? [[String: Any]] else { return }
        sharedDrives = list.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return SharedDrive(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Renamed on Google's side: keep the saved name in step (paths are built from it).
        if let cur = sharedDrive, let now = sharedDrives.first(where: { $0.id == cur.id }), now.name != cur.name {
            useShared(now, uploadHere: uploadToShared)
        }
    }

    /// Picks the drive new uploads go to. Choosing a shared drive also adds it to the Library.
    func useShared(_ d: SharedDrive?, uploadHere: Bool) {
        let changed = d != sharedDrive
        sharedDrive = d
        uploadToShared = d != nil && uploadHere
        guard changed else { return }
        madeSharedFolder = false
        if d == nil { DriveIndex.team.clear() }
        Streamer.shared.restartServer()
        HomeShare.shared.restart()
        Task { await refreshIndex() }
    }
    @ObservationIgnored private var madeSharedFolder = false

    /// The switch: where new downloads end up.
    /// On unless you've chosen otherwise: keeping the Mac empty is what TorrANT is for.
    var straightToDrive: Bool = UserDefaults.standard.object(forKey: "straightToDrive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(straightToDrive, forKey: "straightToDrive") }
    }

    @ObservationIgnored private var daemon: Process?
    @ObservationIgnored private var port = 0
    @ObservationIgnored private let pass = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    private var config: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT/rclone.conf")
    }

    var ready: Bool { Streamer.shared.state == .ready && Streamer.shared.rclone != nil }

    // MARK: Live numbers (read every frame)

    func liveDone(_ j: Job, _ now: Date) -> Double {
        let guess = j.done + j.speed * min(1.5, max(0, now.timeIntervalSince(j.at)))
        return ForwardOnly.shared.step("up:\(j.id)", toward: guess, atLeast: j.done, atMost: j.size > 0 ? j.size : .infinity)
    }
    func liveFraction(_ j: Job, _ now: Date) -> Double { j.size > 0 ? min(1, liveDone(j, now) / j.size) : 0 }
    var totalSpeed: Double { jobs.reduce(0) { $0 + $1.speed } }

    // The speed counter glides from the last reading to the new one instead of jumping.
    @ObservationIgnored private var shownSpeed: Double = 0
    @ObservationIgnored private var fromSpeed: Double = 0
    @ObservationIgnored private var toSpeed: Double = 0
    @ObservationIgnored private var speedAt = Date()

    func liveSpeed(_ now: Date) -> Double {
        let k = min(1, max(0, now.timeIntervalSince(speedAt) / 0.4))
        shownSpeed = fromSpeed + (toSpeed - fromSpeed) * (1 - pow(1 - k, 3))
        return shownSpeed
    }

    private func newSpeedReading(_ total: Double) {
        fromSpeed = shownSpeed
        // Ease into the new reading so one odd sample can't make the dial jump.
        toSpeed = toSpeed == 0 ? total : toSpeed * 0.6 + total * 0.4
        if total == 0 && jobs.isEmpty { toSpeed = 0 }
        speedAt = Date()
    }

    // MARK: Sending

    /// A web link: rclone fetches it and writes it straight into Drive.
    func sendLink(_ link: String) async -> Bool {
        guard ready else { Streamer.shared.connect(); return false }
        guard await ensureDaemon() else { return false }
        // With autoFilename, rclone ignores any folder in "remote", so the folder goes in "fs"
        // (found 8 Nov: a test file landed in the top of My Drive).
        let dest = Uploader.fs(target)
        let r = await call("operations/copyurl", ["fs": "\(dest)\(Uploader.folder)", "remote": "", "url": link,
                                                  "autoFilename": true, "_async": true])
        guard let id = r?["jobid"] as? Int else {
            Colony.shared.say("Couldn't send that link to Drive")
            return false
        }
        let guess = URL(string: link)?.lastPathComponent ?? link
        var job = Job(jobid: id, name: guess.isEmpty ? "Download" : guess, straight: true)
        job.fs = dest
        jobs.append(job)
        Colony.shared.say("Sending \(guess) straight to \(targetName)")
        startPolling()
        return true
    }

    /// A finished file or folder on the Mac: upload it, then delete the Mac copy
    /// (or keep it, with `keepOnMac`). Returns once it's done, true if it's safely in Drive.
    func sendFile(_ local: URL, keepOnMac: Bool = false) async -> Bool {
        guard ready else { Streamer.shared.connect(); return false }
        guard await ensureDaemon() else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) else { return false }
        let name = local.lastPathComponent
        // 32 MB pieces for files already on the Mac: each piece waits for Google's reply before
        // the next goes, so 8 MB spent much of its time waiting. Measured 15 Nov on home Wi-Fi,
        // one 256 MB file: 8M 7.5 / 6.4 MB/s, 32M 9.3, 64M 8.9 / 8.4, 128M 8.1. A dropped
        // connection still only resends one piece. (Links keep 8 MB: see ensureDaemon.)
        let drive = Uploader.fs(target, chunk: true)
        let params: [String: Any] = isDir.boolValue
            ? ["srcFs": local.path, "dstFs": "\(drive)\(Uploader.folder)/\(name)",
               "deleteEmptySrcDirs": !keepOnMac, "_async": true]
            : ["srcFs": local.deletingLastPathComponent().path, "srcRemote": name,
               "dstFs": drive, "dstRemote": "\(Uploader.folder)/\(name)", "_async": true]
        let method = isDir.boolValue ? (keepOnMac ? "sync/copy" : "sync/move")
                                     : (keepOnMac ? "operations/copyfile" : "operations/movefile")
        let r = await call(method, params)
        guard let id = r?["jobid"] as? Int else {
            Colony.shared.say("Couldn't start uploading \(name)")
            return false
        }
        var job = Job(jobid: id, name: name, straight: false)
        job.keep = keepOnMac
        job.fs = Uploader.fs(target)
        job.size = Double(isDir.boolValue ? Colony.folderBytes(local) : Int64((try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
        jobs.append(job)
        Colony.shared.say(keepOnMac ? "Copying \(name) up to \(targetName) (the Mac copy stays)"
                                    : "Flying \(name) up to \(targetName)")
        startPolling()
        let ok = await withCheckedContinuation { waiters[id] = $0 }
        if ok && isDir.boolValue && !keepOnMac { try? FileManager.default.removeItem(at: local) }   // only empty folders left
        return ok
    }

    // MARK: Watching jobs

    private func startPolling() {
        guard !polling else { return }
        polling = true
        Task {
            while !jobs.isEmpty {
                await poll()
                newSpeedReading(totalSpeed)
                try? await Task.sleep(for: .milliseconds(400))
            }
            newSpeedReading(0)
            polling = false
        }
    }

    private func poll() async {
        for j in jobs {
            let stats = await call("core/stats", ["group": "job/\(j.jobid)"])
            let status = await call("job/status", ["jobid": j.jobid])
            guard let i = jobs.firstIndex(where: { $0.id == j.id }) else { continue }
            if let s = stats {
                let tr = (s["transferring"] as? [[String: Any]])?.first
                if let n = tr?["name"] as? String, j.straight {
                    jobs[i].name = (n as NSString).lastPathComponent
                }
                let total = (s["totalBytes"] as? Double) ?? 0
                let size = (tr?["size"] as? Double) ?? 0
                let bytes = (s["bytes"] as? Double) ?? 0
                if max(total, size) > 0 { jobs[i].size = max(jobs[i].size, max(total, size)) }
                if bytes >= jobs[i].done { jobs[i].done = bytes }
                // speedAvg is rclone's own smoothed speed; the instant one jumps around.
                jobs[i].speed = (tr?["speedAvg"] as? Double) ?? (tr?["speed"] as? Double) ?? (s["speed"] as? Double) ?? 0
                jobs[i].at = Date()
            }
            if let st = status, (st["finished"] as? Bool) == true {
                var ok = (st["success"] as? Bool) == true
                let err = st["error"] as? String ?? ""
                let name = jobs[i].name
                let size = jobs[i].size
                let keep = jobs[i].keep
                let fs = jobs[i].fs
                jobs.remove(at: i)
                // Only call it done once Drive itself shows the file in the folder.
                if ok { ok = await confirmInDrive(name, size: size, fs: fs) }
                if ok {
                    Task { await self.refreshIndex() }
                    Colony.shared.say(keep ? "\(name) is in Google Drive ✓ Your Mac copy stays"
                                           : "\(name) is in Google Drive ✓ Nothing left on this Mac")
                    PhoneLink.shared.announceReady(name)
                } else if (st["success"] as? Bool) == true {
                    Colony.shared.say("\(name) uploaded, but it isn't showing in \(Uploader.folder) yet. Check Drive")
                } else if err.contains("invalid_grant") || err.contains("token") {
                    Streamer.shared.state = .notSetUp
                    Colony.shared.say("Google wants you to sign in again (about once a week). \(name) stayed where it was")
                } else {
                    Colony.shared.say("Couldn't upload \(name): \(err.prefix(120))")
                }
                waiters.removeValue(forKey: j.jobid)?.resume(returning: ok)
            }
        }
    }

    /// Reads the whole TorrANT Library from Google (names, sizes, when each arrived) into
    /// DriveIndex, then lets the Library pick up anything new.
    @discardableResult
    func refreshIndex() async -> Bool {
        guard ready, !indexing, await ensureDaemon() else { return false }
        indexing = true
        defer { indexing = false }
        guard let r = await call("operations/list", ["fs": "drive:\(Uploader.folder)", "remote": "",
                                                     "opt": ["recurse": true, "metadata": true]], timeout: 60),
              let list = r["list"] as? [[String: Any]] else { return false }
        var changed = DriveIndex.shared.load(list, root: Colony.shared.libraryRoot)
        // The shared drive's TorrANT Library too (made the first time, so a new drive lists empty).
        if let shared = sharedDrive, let root = Colony.shared.sharedRoot {
            let fs = Uploader.fs(shared)
            if !madeSharedFolder, await call("operations/mkdir", ["fs": fs, "remote": Uploader.folder], timeout: 30) != nil {
                madeSharedFolder = true
            }
            if let r2 = await call("operations/list", ["fs": "\(fs)\(Uploader.folder)", "remote": "",
                                                       "opt": ["recurse": true, "metadata": true]], timeout: 60),
               let list2 = r2["list"] as? [[String: Any]] {
                if DriveIndex.team.load(list2, root: root) { changed = true }
            }
        } else {
            DriveIndex.team.clear()
        }
        // The streaming server keeps folder listings for an hour and, serving both drives as
        // one, doesn't hear about new files on its own (15 Nov: a new film gave "not found").
        if changed { await Streamer.shared.forgetFolders() }
        await LibraryStore.shared.refresh()
        return true
    }
    @ObservationIgnored private var indexing = false

    /// Looks the file (or folder) up in TorrANT Library and checks the size where known.
    private func confirmInDrive(_ name: String, size: Double, fs: String) async -> Bool {
        guard let r = await call("operations/stat", ["fs": "\(fs)\(Uploader.folder)", "remote": name]),
              let item = r["item"] as? [String: Any] else { return false }
        if (item["IsDir"] as? Bool) == true { return true }
        let got = (item["Size"] as? Double) ?? -1
        return size <= 0 || got == size || got < 0
    }

    // MARK: rclone control server

    /// One start at a time: two uploads asking together (15 Nov, the stuck-upload rescue)
    /// each launched their own rclone, and jobs could land on the one TorrANT wasn't watching.
    @ObservationIgnored private var starting: Task<Bool, Never>?

    private func ensureDaemon() async -> Bool {
        if let d = daemon, d.isRunning { return true }
        if let s = starting { return await s.value }
        let t = Task { await startDaemon() }
        starting = t
        let ok = await t.value
        starting = nil
        return ok
    }

    private func startDaemon() async -> Bool {
        if let d = daemon, d.isRunning { return true }
        guard let rclone = Streamer.shared.rclone else { return false }
        for _ in 0..<5 {
            let tryPort = Int.random(in: 40000...60000)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: rclone)
            p.arguments = ["rcd", "--config", config.path, "--rc-addr", "127.0.0.1:\(tryPort)",
                           "--rc-user", "ant", "--rc-pass", pass,
                           "--drive-pacer-min-sleep", "10ms", "--drive-pacer-burst", "200",
                           // rclone's default 8 MB upload pieces: a link is fetched and sent piece
                           // by piece, so small pieces keep both moving. 64 MB (tried 8 Nov) made it
                           // download 64 MB, then upload it, so progress stalled and jumped.
                           // 8 at a time: a season is a few big files, but an unpacked zip
                           // can be hundreds of tiny ones and Drive takes ~1 s to file each.
                           // At 2 at a time, 692 small files took over 15 minutes (8 Nov).
                           "--transfers", "8", "--checkers", "16",
                           // A failed 8 MB piece is retried on its own (low-level retry) before
                           // the whole file starts over. 20 rode out ~40 s of no network; the
                           // Wi-Fi here drops for up to 2 min (15 Nov), so allow ~10 min.
                           "--retries", "5", "--low-level-retries", "300"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { continue }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(150))
                if !p.isRunning { break }
                port = tryPort
                if await call("rc/noop", [:]) != nil { daemon = p; return true }
            }
            p.terminate()
        }
        Colony.shared.say("Couldn't start the Drive uploader")
        return false
    }

    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 10) async -> [String: Any]? {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/\(method)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Basic " + Data("ant:\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: params)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func stop() {
        daemon?.terminate(); daemon = nil
    }
}
