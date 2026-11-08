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

    static let videoKinds: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "wmv", "flv"]

    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT", isDirectory: true)
    }
    private var config: URL { support.appendingPathComponent("rclone.conf") }

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
        p.arguments = ["config", "create", "drive", "drive", "scope=drive.readonly", "--config", config.path]
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

    /// Plays a file: from disk if it's all here, otherwise streamed.
    func play(_ file: URL) async {
        if Streamer.isOnMac(file) {
            open([file])
            return
        }
        guard let link = await streamLink(for: file) else { return }
        open([link])
    }

    /// Plays every episode in a season folder, in order, as one VLC playlist.
    func playSeason(_ folder: URL, from start: URL? = nil) async {
        var eps = Streamer.episodes(in: folder)
        if let start, let i = eps.firstIndex(of: start) { eps = Array(eps[i...]) }
        guard !eps.isEmpty else {
            Colony.shared.say("No videos in \(folder.lastPathComponent)")
            return
        }
        var lines = ["#EXTM3U"]
        for e in eps {
            let link: URL?
            if Streamer.isOnMac(e) { link = e } else { link = await streamLink(for: e) }
            guard let link else { return }
            lines.append("#EXTINF:-1,\(e.deletingPathExtension().lastPathComponent)")
            lines.append(link.isFileURL ? link.path : link.absoluteString)
        }
        let list = support.appendingPathComponent("playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: list, withIntermediateDirectories: true)
        let m3u = list.appendingPathComponent("\(folder.lastPathComponent).m3u")
        try? lines.joined(separator: "\n").write(to: m3u, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: m3u.path)
        open([m3u])
    }

    private func open(_ urls: [URL]) {
        guard let vlc else {
            Colony.shared.say("VLC isn't installed")
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: vlc, configuration: NSWorkspace.OpenConfiguration())
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
                           "--read-only", "--vfs-cache-mode", "off",
                           // Small reads: VLC jumps around a file's index before playing,
                           // and big read-ahead blocks wasted ~120 MB per start in testing.
                           "--buffer-size", "4M", "--vfs-read-chunk-size", "4M",
                           "--vfs-read-chunk-size-limit", "64M", "--dir-cache-time", "1m"]
            p.standardOutput = Pipe(); p.standardError = Pipe()
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
        Colony.shared.say("Couldn't start streaming. Check the internet and try again")
        return false
    }

    func stop() {
        server?.terminate(); server = nil
        signIn?.terminate(); signIn = nil
        try? FileManager.default.removeItem(at: support.appendingPathComponent("playlists"))
    }

    // MARK: Helpers

    nonisolated static func answers(port: Int, user: String, pass: String) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
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
