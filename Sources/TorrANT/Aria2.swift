import Foundation

enum EngineError: LocalizedError {
    case missing, badReply
    var errorDescription: String? {
        switch self {
        case .missing: return "Couldn't find the download engine (aria2c)."
        case .badReply: return "The download engine sent a reply we couldn't read."
        }
    }
}

struct RPCError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

/// Runs aria2c in the background and talks to it over JSON-RPC on
/// 127.0.0.1 only, guarded by a random per-launch secret.
final class Aria2: @unchecked Sendable {
    let port: Int
    private let secret: String
    private var process: Process?
    private let http: URLSession

    init() {
        port = Int.random(in: 46100...46899)
        secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.connectionProxyDictionary = [:]
        http = URLSession(configuration: cfg)
    }

    static func binary() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("aria2/aria2c"))
        }
        candidates += ["/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c"].map(URL.init(fileURLWithPath:))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func start(downloadDir: URL, support: URL) throws {
        guard let bin = Aria2.binary() else { throw EngineError.missing }
        let fm = FileManager.default
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let session = support.appendingPathComponent("colony.session")
        if !fm.fileExists(atPath: session.path) { fm.createFile(atPath: session.path, contents: Data()) }

        let args = [
            "--enable-rpc=true",
            "--rpc-listen-all=false",
            "--rpc-listen-port=\(port)",
            "--rpc-secret=\(secret)",
            "--rpc-max-request-size=16M",
            // Don't drop "<hash>.torrent" copies into the user's Downloads;
            // the app keeps its own copies in Application Support.
            "--rpc-save-upload-metadata=false",
            "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
            "--dir=\(downloadDir.path)",
            "--input-file=\(session.path)",
            "--save-session=\(session.path)",
            "--save-session-interval=15",
            // Resume uses .aria2 control files. Without this, a different file that
            // happens to share a name in Downloads would be "resumed" (or counted
            // as done) instead of saved as name.1.ext.
            "--continue=false",
            "--max-concurrent-downloads=8",
            // "8 ants dragging it home": one normal link, 8 parallel connections
            "--split=8",
            "--max-connection-per-server=8",
            "--min-split-size=1M",
            "--file-allocation=none",
            "--auto-file-renaming=true",
            "--enable-dht=true",
            "--dht-file-path=\(support.appendingPathComponent("dht.dat").path)",
            "--bt-enable-lpd=true",
            "--enable-peer-exchange=true",
            "--bt-max-peers=80",
            "--seed-ratio=1.0",
            "--follow-torrent=mem",
            "--bt-save-metadata=false",
            "--user-agent=TorrANT/0.1",
            "--console-log-level=warn",
            "--log-level=warn",
            "--log=\(support.appendingPathComponent("engine.log").path)",
            "--summary-interval=0",
            "--quiet=true",
        ]
        let p = Process()
        // The copy inside the app brings OpenSSL's plug-ins; tell OpenSSL where they are so it
        // never reaches for a Homebrew install (which a friend's Mac won't have).
        if let mods = Bundle.main.resourceURL?.appendingPathComponent("aria2/lib/ossl-modules"),
           FileManager.default.fileExists(atPath: mods.path) {
            var env = ProcessInfo.processInfo.environment
            env["OPENSSL_MODULES"] = mods.path
            p.environment = env
        }
        p.executableURL = bin
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func stop() {
        // SIGTERM makes aria2 save its session before exiting.
        process?.terminate()
    }

    @discardableResult
    func call(_ method: String, _ params: [Any] = []) async throws -> Any {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/jsonrpc")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": "torrant", "method": method,
            "params": ["token:\(secret)"] + params,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await http.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.badReply
        }
        if let e = obj["error"] as? [String: Any] {
            throw RPCError(code: e["code"] as? Int ?? 0, message: e["message"] as? String ?? "Engine error")
        }
        return obj["result"] ?? NSNull()
    }
}
