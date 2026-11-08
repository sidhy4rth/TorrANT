import AppKit

/// Brave hand-off ("Crumb spotted" in the browser).
///
/// The TorrANT Catcher extension sends each Brave download to the small
/// `torrant-catch` helper (Brave's native messaging), which forwards it here
/// over a Unix socket only this user can open. On launch we also register the
/// helper with Brave and keep a copy of the extension in Application Support
/// so it can be loaded unpacked from a stable folder.
final class Catcher: @unchecked Sendable {
    static let shared = Catcher()

    static let hostName = "com.sidhy4rth.torrant"
    static let extensionID = "ijnbceipkhodakjopoiccigfkphlokhf"

    private var listener: Int32 = -1

    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT", isDirectory: true)
    }
    static var socketPath: String { support.appendingPathComponent("catch.sock").path }
    static var extensionFolder: URL { support.appendingPathComponent("BraveExtension", isDirectory: true) }

    /// Where Brave looks for helpers. Brave on macOS reads Chrome's folder
    /// (its own folder alone gives "native messaging host not found"), so we
    /// register in both, but only when Brave is installed.
    private static var hostFolders: [URL] {
        let lib = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard FileManager.default.fileExists(atPath: lib.appendingPathComponent("BraveSoftware/Brave-Browser").path)
        else { return [] }
        return ["BraveSoftware/Brave-Browser/NativeMessagingHosts", "Google/Chrome/NativeMessagingHosts"]
            .map { lib.appendingPathComponent($0, isDirectory: true) }
    }

    func start() {
        // A hung-up helper must never take the app down with it.
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(at: Catcher.support, withIntermediateDirectories: true)
        Catcher.installHost()
        Catcher.syncExtension()
        listen()
    }

    // MARK: Brave setup

    /// Tells Brave where the helper lives and that only our extension may use it.
    private static func installHost() {
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("torrant-catch"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "TorrANT: takes downloads from Brave",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        for folder in hostFolders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(hostName).json")
            if (try? Data(contentsOf: file)) != data { try? data.write(to: file, options: .atomic) }
        }
    }

    /// Copies the bundled extension to a stable folder, only touching files that changed.
    private static func syncExtension() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("BraveExtension"),
              let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let fm = FileManager.default
        for case let file as URL in walker {
            let rel = file.path.dropFirst(source.path.count + 1)
            let dest = extensionFolder.appendingPathComponent(String(rel))
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            guard let data = try? Data(contentsOf: file) else { continue }
            if (try? Data(contentsOf: dest)) == data { continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest, options: .atomic)
        }
    }

    static func revealExtension() {
        syncExtension()
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
    }

    // MARK: Socket

    private func listen() {
        let path = Catcher.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); return }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { close(fd); return }
        listener = fd

        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                Thread.detachNewThread { self.serve(client) }
            }
        }
    }

    func stop() {
        if listener >= 0 { close(listener); listener = -1 }
        unlink(Catcher.socketPath)
    }

    private final class Box: @unchecked Sendable { var value: [String: Any] = ["ok": false] }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        // Brave is waiting: wake up even if macOS has napped us in the background.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Download from Brave")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while !data.contains(0x0A), data.count < 4 * 1024 * 1024 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let line = data.split(separator: 0x0A).first ?? Data()
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return }

        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await Catcher.handle(msg)
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut { box.value = ["ok": false, "reason": "TorrANT was too busy"] }

        guard var out = try? JSONSerialization.data(withJSONObject: box.value) else { return }
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
    }

    @MainActor
    private static func handle(_ msg: [String: Any]) async -> [String: Any] {
        let colony = Colony.shared
        switch msg["type"] as? String {
        case "ping":
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return ["ok": true, "version": version, "online": colony.online]
        case "catch":
            let problem = await colony.catchFromBrowser(
                url: msg["url"] as? String ?? "",
                cookies: msg["cookies"] as? String ?? "",
                referrer: msg["referrer"] as? String ?? "",
                userAgent: msg["userAgent"] as? String ?? "",
                filename: msg["filename"] as? String ?? "")
            return problem == nil ? ["ok": true] : ["ok": false, "reason": problem!]
        default:
            return ["ok": false, "reason": "unknown message"]
        }
    }
}
