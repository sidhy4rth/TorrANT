import AppKit
import Foundation

/// "Straight to Google Drive" mode. rclone's control server does the uploading into the
/// TorrANT Library folder, with the same sign-in streaming uses (read Drive, and create
/// or change only files TorrANT made).
///  · A plain link streams from the web straight into Drive: no Mac disk at all.
///  · A finished download on the Mac (torrents, Brave catches) is unpacked if it's a zip,
///    moved up, and the Mac copy deleted once Drive has it.
@MainActor @Observable
final class Uploader {
    static let shared = Uploader()
    static let folder = "TorrANT Library"

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let jobid: Int
        var name: String
        let straight: Bool          // link → Drive, nothing on the Mac
        var size: Double = 0
        var done: Double = 0
        var speed: Double = 0
        var at = Date()
    }

    var jobs: [Job] = []

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
        let r = await call("operations/copyurl", ["fs": "drive:\(Uploader.folder)", "remote": "", "url": link,
                                                  "autoFilename": true, "_async": true])
        guard let id = r?["jobid"] as? Int else {
            Colony.shared.say("Couldn't send that link to Drive")
            return false
        }
        let guess = URL(string: link)?.lastPathComponent ?? link
        jobs.append(Job(jobid: id, name: guess.isEmpty ? "Download" : guess, straight: true))
        Colony.shared.say("Sending \(guess) straight to Google Drive")
        startPolling()
        return true
    }

    /// A finished file or folder on the Mac: upload it, then delete the Mac copy.
    /// Returns once it's done, true if it's safely in Drive.
    func sendFile(_ local: URL) async -> Bool {
        guard ready else { Streamer.shared.connect(); return false }
        guard await ensureDaemon() else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) else { return false }
        let name = local.lastPathComponent
        let params: [String: Any] = isDir.boolValue
            ? ["srcFs": local.path, "dstFs": "drive:\(Uploader.folder)/\(name)",
               "deleteEmptySrcDirs": true, "_async": true]
            : ["srcFs": local.deletingLastPathComponent().path, "srcRemote": name,
               "dstFs": "drive:", "dstRemote": "\(Uploader.folder)/\(name)", "_async": true]
        let r = await call(isDir.boolValue ? "sync/move" : "operations/movefile", params)
        guard let id = r?["jobid"] as? Int else {
            Colony.shared.say("Couldn't start uploading \(name)")
            return false
        }
        var job = Job(jobid: id, name: name, straight: false)
        job.size = Double(isDir.boolValue ? Colony.folderBytes(local) : Int64((try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
        jobs.append(job)
        Colony.shared.say("Flying \(name) up to Google Drive")
        startPolling()
        let ok = await withCheckedContinuation { waiters[id] = $0 }
        if ok && isDir.boolValue { try? FileManager.default.removeItem(at: local) }   // only empty folders left
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
                jobs.remove(at: i)
                // Only call it done once Drive itself shows the file in the folder.
                if ok { ok = await confirmInDrive(name, size: size) }
                if ok {
                    Colony.shared.say("\(name) is in Google Drive ✓ Nothing left on this Mac")
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

    /// Looks the file (or folder) up in TorrANT Library and checks the size where known.
    private func confirmInDrive(_ name: String, size: Double) async -> Bool {
        guard let r = await call("operations/stat", ["fs": "drive:\(Uploader.folder)", "remote": name]),
              let item = r["item"] as? [String: Any] else { return false }
        if (item["IsDir"] as? Bool) == true { return true }
        let got = (item["Size"] as? Double) ?? -1
        return size <= 0 || got == size || got < 0
    }

    // MARK: rclone control server

    private func ensureDaemon() async -> Bool {
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
                           "--retries", "5", "--low-level-retries", "20"]
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

    private func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/\(method)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
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
