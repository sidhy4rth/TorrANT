import AppKit
import Foundation

/// Real streaming from Google Drive. Google's own app downloads a whole file before
/// any player can open it, so TorrANT runs rclone (read-only access to Drive) as a
/// small web server on this Mac, and VLC fetches only the part being watched.
@MainActor @Observable
final class Streamer {
    static let shared = Streamer()

    enum State: Equatable { case notSetUp, signingIn, ready, problem(String) }

    var state: State = .notSetUp

    @ObservationIgnored private var server: Process?
    @ObservationIgnored private var port = 0
    @ObservationIgnored private let user = "ant"
    @ObservationIgnored private let pass = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    @ObservationIgnored private var signIn: Process?
    @ObservationIgnored private var serverLog: Pipe?
    @ObservationIgnored private var player: Process?
    @ObservationIgnored private var vlcPort = 0
    @ObservationIgnored private let vlcPass = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    /// Every 3 s while VLC plays: which file, where you are, how long it is.
    private func watchPlayer(_ p: Process) {
        let (port, pass) = (vlcPort, vlcPass)
        Task {
            try? await Task.sleep(for: .seconds(2))
            while p.isRunning {
                if let s = await Streamer.vlcStatus(port: port, pass: pass) {
                    WatchLog.shared.note(file: s.file, at: s.time, of: s.length)
                }
                try? await Task.sleep(for: .seconds(3))
            }
            WatchLog.shared.save()
        }
    }

    nonisolated static func vlcStatus(port: Int, pass: String) async -> (file: String, time: Double, length: Double)? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/requests/status.json") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.setValue("Basic " + Data(":\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (d["state"] as? String) == "playing" || (d["state"] as? String) == "paused",
              let info = d["information"] as? [String: Any],
              let cat = info["category"] as? [String: Any],
              let meta = cat["meta"] as? [String: Any],
              let file = meta["filename"] as? String else { return nil }
        let time = (d["time"] as? Double) ?? Double(d["time"] as? Int ?? 0)
        let length = (d["length"] as? Double) ?? Double(d["length"] as? Int ?? 0)
        return (file.removingPercentEncoding ?? file, time, length)
    }

    nonisolated static let videoKinds: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "wmv", "flv"]

    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT", isDirectory: true)
    }
    private var config: URL { support.appendingPathComponent("rclone.conf") }
    /// Preloaded starts and what's playing now (max 1 GB, cleared after a day). In Caches, so macOS may clear it too.
    private var streamCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT/stream", isDirectory: true)
    }

    var rclone: String? {
        ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var vlc: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc")
    }

    init() { refreshState() }

    func refreshState() {
        guard signIn == nil else { return }
        let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        state = text.contains("[drive]") && text.contains("token") ? .ready : .notSetUp
    }

    // MARK: Sign-in (once)

    /// Opens the browser for a one-time, read-only Google sign-in.
    func connect() {
        guard signIn == nil else { return }
        guard let rclone else {
            state = .problem("rclone isn't installed")
            return
        }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclone)
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        // Signing in again keeps the private Google key; only a first setup creates the remote.
        p.arguments = existing.contains("client_id")
            ? ["config", "update", "drive", "config_refresh_token", "true", "--config", config.path]
            : ["config", "create", "drive", "drive", "scope=drive.readonly", "--config", config.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                Streamer.shared.signIn = nil
                Streamer.shared.refreshState()
                if !ok { Streamer.shared.state = .problem("Sign-in didn't finish. Try again.") }
                Colony.shared.say(ok ? "Streaming is set up ✓ Press ▶ on anything in Drive" : "Streaming sign-in didn't finish")
            }
        }
        do {
            try p.run()
            signIn = p
            state = .signingIn
            Colony.shared.say("Finish signing in to Google in your browser")
        } catch {
            state = .problem(error.localizedDescription)
        }
    }

    // MARK: Playing

    /// Plays a file: from disk if it's all here, otherwise streamed. Resumes where you left off.
    func play(_ file: URL) async {
        await playList([file], title: file.deletingPathExtension().lastPathComponent)
    }

    /// Builds a VLC playlist (stream links, or the file itself when it's on this Mac). The first
    /// video starts where you stopped last time; the rest start from the top.
    private func playList(_ files: [URL], title: String) async {
        var lines = ["#EXTM3U"]
        for (i, e) in files.enumerated() {
            let link: URL?
            if Streamer.isOnMac(e) { link = e } else { link = await streamLink(for: e) }
            guard let link else { return }
            if i == 0, let at = WatchLog.shared.resumeAt(e.lastPathComponent) {
                lines.append("#EXTVLCOPT:start-time=\(Int(at))")
            }
            lines.append("#EXTINF:-1,\(e.deletingPathExtension().lastPathComponent)")
            lines.append(link.isFileURL ? link.path : link.absoluteString)
        }
        let list = support.appendingPathComponent("playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: list, withIntermediateDirectories: true)
        let safe = title.replacingOccurrences(of: "/", with: "-")
        let m3u = list.appendingPathComponent("\(safe).m3u")
        try? lines.joined(separator: "\n").write(to: m3u, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: m3u.path)
        launch([m3u.path])
    }

    @ObservationIgnored private var preloaded: Set<String> = []
    @ObservationIgnored private var warming = false

    /// Starts the server, looks up the Drive folder, and pre-loads the first and last 4 MB of
    /// every video (where a video's header and seek index live), like YouTube preloading the
    /// start. Tested 8 Nov: start 3.5–4 s → 2.2 s. Lives in the 1 GB cache for up to a day. Runs at launch and whenever the Drive page opens.
    func warmUp() {
        guard state == .ready, !warming, !NetWatch.shared.metered else { return }
        warming = true
        Task {
            defer { warming = false }
            guard await startServer(), let dir = Colony.shared.driveDir else { return }
            let videos = await Task.detached(priority: .utility) {
                Streamer.episodes(in: dir).map { u in
                    (u, Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
                }
            }.value
            let todo = videos.filter { !preloaded.contains($0.0.path) && $0.1 > 16_000_000 && !Streamer.isOnMac($0.0) }
            let (port, user, pass) = (self.port, self.user, self.pass)
            await withTaskGroup(of: (String, Bool).self) { group in
                var running = 0
                for (file, size) in todo {
                    guard let rel = Streamer.pathInDrive(file) else { continue }
                    if running >= 3, let (path, ok) = await group.next() {
                        if ok { preloaded.insert(path) }
                        running -= 1
                    }
                    group.addTask {
                        let head = await Streamer.fetch(port: port, user: user, pass: pass, path: rel, range: "bytes=0-4194303")
                        let tail = await Streamer.fetch(port: port, user: user, pass: pass, path: rel,
                                                        range: "bytes=\(size - 4_194_304)-\(size - 1)")
                        return (file.path, head && tail)
                    }
                    running += 1
                }
                for await (path, ok) in group where ok { preloaded.insert(path) }
            }
        }
    }

    nonisolated static func fetch(port: Int, user: String, pass: String, path: String, range: String) async -> Bool {
        let p = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0)
        }.joined(separator: "/")
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(p)") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Basic " + Data("\(user):\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue(range, forHTTPHeaderField: "Range")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 206
    }

    /// Plays every episode in a season folder, in order, as one VLC playlist.
    func playSeason(_ folder: URL, from start: URL? = nil) async {
        var eps = Streamer.episodes(in: folder)
        if let start, let i = eps.firstIndex(of: start) { eps = Array(eps[i...]) }
        guard !eps.isEmpty else {
            Colony.shared.say("No videos in \(folder.lastPathComponent)")
            return
        }
        // No episode picked: carry on from the one you were last watching.
        if start == nil, let next = WatchLog.shared.nextUp(in: eps), let i = eps.firstIndex(of: next) {
            eps = Array(eps[i...])
        }
        await playList(eps, title: folder.lastPathComponent)
    }

    /// One VLC window that TorrANT owns, set up to buffer like YouTube:
    /// ~1 s of video before it plays, then up to 128 MB (several minutes) read ahead,
    /// and it reconnects on its own if the Wi-Fi drops for a moment.
    private func launch(_ items: [String]) {
        guard let vlc else {
            Colony.shared.say("VLC isn't installed")
            return
        }
        if let old = player, old.isRunning { old.terminate() }
        let p = Process()
        p.executableURL = vlc.appendingPathComponent("Contents/MacOS/VLC")
        vlcPort = Int.random(in: 40000...60000)
        p.arguments = [// VLC's own little web interface, only on this Mac, so TorrANT can
                       // see where you are and resume there next time.
                       "--extraintf=http", "--http-host=127.0.0.1", "--http-port=\(vlcPort)",
                       "--http-password=\(vlcPass)",
                       "--network-caching=1000", "--file-caching=1000",
                       "--prefetch-buffer-size=131072", "--prefetch-read-size=1048576",
                       "--http-reconnect", "--no-video-title-show",
                       // No extra trips: don't scan the folder for linked .mkv parts,
                       // don't look up artwork online, don't pre-read the playlist.
                       "--no-mkv-preload-local-dir", "--no-metadata-network-access", "--no-auto-preparse"] + items
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            player = p
            NSRunningApplication(processIdentifier: p.processIdentifier)?.activate()
            watchPlayer(p)
        } catch {
            Colony.shared.say("Couldn't open VLC: \(error.localizedDescription)")
        }
    }

    /// The streaming link for a file in Google Drive, starting the little server if needed.
    func streamLink(for file: URL) async -> URL? {
        guard state == .ready else {
            if state != .signingIn { connect() }
            Colony.shared.say("Set up streaming first: finish the Google sign-in, then press ▶ again")
            return nil
        }
        guard let rel = Streamer.pathInDrive(file) else {
            Colony.shared.say("\(file.lastPathComponent) isn't in Google Drive")
            return nil
        }
        guard await startServer() else { return nil }
        let encoded = rel.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "http://\(user):\(pass)@127.0.0.1:\(port)/\(encoded)")
    }

    private func startServer() async -> Bool {
        if let s = server, s.isRunning { return true }
        guard let rclone else { Colony.shared.say("rclone isn't installed"); return false }
        for _ in 0..<5 {
            let tryPort = Int.random(in: 40000...60000)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: rclone)
            p.arguments = ["serve", "http", "drive:", "--config", config.path,
                           "--addr", "127.0.0.1:\(tryPort)", "--user", user, "--pass", pass,
                           "--read-only",
                           // Like YouTube, tested 8 Nov on a 2.2 GB movie with scripted skips:
                           // a disk cache keeps the file's index and every part already watched
                           // (start 9.3 s → 5.1 s, long skip 5.4 → 3.7 s, back to a watched
                           // spot ~instant). Read-ahead stays small (48 MB) because a big one
                           // kept old spots downloading and slowed later skips; VLC does the
                           // long read-ahead itself.
                           "--vfs-cache-mode", "full", "--cache-dir", streamCache.path,
                           "--vfs-read-ahead", "48M",
                           // Space matters more than keeping watched parts: a hard 1 GB cap
                           // (checked every 30 s), oldest out first. It mostly holds the
                           // preloaded starts; what you watch is pushed out as you go.
                           "--vfs-cache-max-size", "1G", "--vfs-cache-max-age", "24h",
                           "--vfs-cache-poll-interval", "30s",
                           // Own Google key, so rclone may ask Google faster than its shared-key default.
                           "--drive-pacer-min-sleep", "10ms", "--drive-pacer-burst", "200",
                           "--vfs-fast-fingerprint",
                           // Small first read so a jump starts fast, then doubling to big reads.
                           "--vfs-read-chunk-size", "8M", "--vfs-read-chunk-size-limit", "off",
                           "--buffer-size", "16M", "--dir-cache-time", "1h"]
            let err = Pipe()
            p.standardOutput = Pipe(); p.standardError = err
            serverLog = err
            do { try p.run() } catch { continue }
            // Ready when it answers on the port.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(150))
                if !p.isRunning { break }
                if await Streamer.answers(port: tryPort, user: user, pass: pass) {
                    server = p; port = tryPort
                    return true
                }
            }
            p.terminate()
        }
        if let log = serverLog, let text = String(data: log.fileHandleForReading.availableData, encoding: .utf8),
           text.contains("invalid_grant") || text.contains("token expired") {
            state = .notSetUp
            Colony.shared.say("Google wants you to sign in again for streaming (it asks about once a week)")
        } else {
            Colony.shared.say("Couldn't start streaming. Check the internet and try again")
        }
        return false
    }

    func stop() {
        server?.terminate(); server = nil
        if let p = player, p.isRunning { p.terminate() }
        player = nil
        signIn?.terminate(); signIn = nil
        try? FileManager.default.removeItem(at: support.appendingPathComponent("playlists"))
    }

    // MARK: Helpers

    nonisolated static func answers(port: Int, user: String, pass: String, path: String = "") async -> Bool {
        let p = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(p)\(p.isEmpty ? "" : "/")") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 1)
        req.httpMethod = "HEAD"
        req.setValue("Basic " + Data("\(user):\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// "Movies/x.mkv" for ".../GoogleDrive-…/My Drive/Movies/x.mkv".
    nonisolated static func pathInDrive(_ file: URL) -> String? {
        let parts = file.standardizedFileURL.pathComponents
        guard let i = parts.firstIndex(where: { $0.hasPrefix("GoogleDrive-") }),
              i + 1 < parts.count, parts[i + 1] == "My Drive" else { return nil }
        let rest = parts[(i + 2)...]
        return rest.isEmpty ? nil : rest.joined(separator: "/")
    }

    nonisolated static func isOnMac(_ file: URL) -> Bool {
        let v = try? file.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        let size = Int64(v?.fileSize ?? 0), here = Int64(v?.totalFileAllocatedSize ?? 0)
        return size > 0 && here >= size * 9 / 10
    }

    nonisolated static func isVideo(_ url: URL) -> Bool { videoKinds.contains(url.pathExtension.lowercased()) }

    nonisolated static func episodes(in folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter(isVideo)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
