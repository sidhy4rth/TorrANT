import Foundation

enum Kind: String, Codable { case swarm, crumb }

enum CrumbState: Equatable { case active, waiting, paused, seeding, complete, error, removed }

struct CrumbFile: Identifiable, Hashable {
    let index: Int
    let path: String
    let length: Int64
    let done: Int64
    let selected: Bool
    var id: Int { index }
    var name: String { (path as NSString).lastPathComponent }
}

/// One download, as the colony sees it.
struct Crumb: Identifiable, Hashable {
    let gid: String
    let name: String
    let kind: Kind
    let state: CrumbState
    let total: Int64
    let done: Int64
    let uploaded: Int64
    let down: Int
    let up: Int
    let connections: Int
    let seeders: Int
    let files: [CrumbFile]
    let dir: String
    let errorMessage: String?
    let isMetadata: Bool
    let followedBy: [String]
    let source: String?
    // When this reading arrived, and the speed one reading earlier, so the
    // screen can glide between readings instead of jumping.
    var sampledAt = Date()
    var prevDown = 0

    var id: String { gid }

    /// Same download, same numbers = no redraw (the reading time doesn't count).
    static func == (a: Crumb, b: Crumb) -> Bool {
        a.gid == b.gid && a.state == b.state && a.done == b.done && a.total == b.total &&
        a.down == b.down && a.up == b.up && a.uploaded == b.uploaded && a.connections == b.connections &&
        a.seeders == b.seeders && a.name == b.name && a.errorMessage == b.errorMessage &&
        a.isMetadata == b.isMetadata && a.files == b.files && a.dir == b.dir && a.prevDown == b.prevDown
    }
    func hash(into h: inout Hasher) { h.combine(gid) }

    var progress: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var eta: TimeInterval? { down > 0 && total > done ? Double(total - done) / Double(down) : nil }
    var ratio: Double { done > 0 ? Double(uploaded) / Double(done) : 0 }
    var isHome: Bool { total > 0 && done >= total && !isMetadata }

    /// Where the finished thing lives on disk.
    var homePath: String {
        if kind == .swarm, files.count > 1 { return (dir as NSString).appendingPathComponent(name) }
        return files.first(where: { !$0.path.isEmpty })?.path ?? (dir as NSString).appendingPathComponent(name)
    }

    init?(_ d: [String: Any]) {
        func s(_ k: String) -> String { d[k] as? String ?? "" }
        func i(_ k: String) -> Int64 { Int64(s(k)) ?? 0 }
        guard let gid = d["gid"] as? String else { return nil }
        self.gid = gid
        let bt = d["bittorrent"] as? [String: Any]
        let info = bt?["info"] as? [String: Any]
        let rawFiles = d["files"] as? [[String: Any]] ?? []
        files = rawFiles.compactMap { f in
            guard let idx = Int(f["index"] as? String ?? "") else { return nil }
            return CrumbFile(index: idx,
                             path: f["path"] as? String ?? "",
                             length: Int64(f["length"] as? String ?? "") ?? 0,
                             done: Int64(f["completedLength"] as? String ?? "") ?? 0,
                             selected: (f["selected"] as? String ?? "true") == "true")
        }
        let firstPath = files.first?.path ?? ""
        isMetadata = bt != nil && (info == nil || firstPath.hasPrefix("[METADATA]"))
        kind = bt != nil ? .swarm : .crumb

        let firstURI = ((rawFiles.first?["uris"] as? [[String: Any]])?.first?["uri"] as? String)
        source = firstURI
        if let n = info?["name"] as? String, !n.isEmpty {
            name = n
        } else if !firstPath.isEmpty, !firstPath.hasPrefix("[METADATA]") {
            name = (firstPath as NSString).lastPathComponent
        } else if isMetadata {
            name = Crumb.magnetName(firstPath) ?? "Unnamed swarm"
        } else if let u = firstURI, let url = URL(string: u), !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" {
            name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        } else {
            name = "Unnamed crumb"
        }

        total = i("totalLength")
        done = i("completedLength")
        uploaded = i("uploadLength")
        down = Int(i("downloadSpeed"))
        up = Int(i("uploadSpeed"))
        connections = Int(i("connections"))
        seeders = Int(i("numSeeders"))
        dir = s("dir")
        followedBy = d["followedBy"] as? [String] ?? []
        let err = s("errorMessage")
        errorMessage = err.isEmpty ? nil : err

        switch s("status") {
        case "active": state = (s("seeder") == "true" && kind == .swarm) ? .seeding : .active
        case "waiting": state = .waiting
        case "paused": state = .paused
        case "complete": state = .complete
        case "error": state = .error
        default: state = .removed
        }
    }

    private static func magnetName(_ metaPath: String) -> String? {
        // aria2 shows "[METADATA]<name or hash>"
        let n = metaPath.replacingOccurrences(of: "[METADATA]", with: "")
        return n.isEmpty ? nil : n
    }

    static let rpcKeys = ["gid", "status", "totalLength", "completedLength", "uploadLength",
                          "downloadSpeed", "uploadSpeed", "connections", "numSeeders", "seeder",
                          "files", "bittorrent", "dir", "errorMessage", "followedBy"]
}

/// Something the ants brought home (kept across launches).
struct HillItem: Codable, Identifiable, Hashable {
    var id = UUID()
    let name: String
    var path: String
    let size: Int64
    let kind: Kind
    let date: Date
}

struct Chatter: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let text: String
}

struct Peer: Identifiable, Hashable {
    let id: String
    let ip: String
    let down: Int
    let up: Int
    let seeder: Bool
}

struct PendingTorrent: Identifiable {
    let gid: String
    let name: String
    let files: [CrumbFile]
    let saved: String          // our private copy of the .torrent
    var id: String { gid }
}

/// A .torrent the colony is working on, remembered across launches.
struct SavedSwarm: Codable, Hashable {
    let file: String
    var dir: String
    var select: String?
    var paused: Bool
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: b)
    }
    static func speed(_ bps: Int) -> String {
        bps <= 0 ? "0 KB/s" : ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }
    /// Big-number style: ("18.4", "MB/s")
    static func speedParts(_ bps: Int) -> (String, String) {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = Double(max(bps, 0)), u = 0
        while v >= 1000 && u < units.count - 1 { v /= 1000; u += 1 }
        return (v >= 100 || u == 0 ? String(format: "%.0f", v) : String(format: "%.1f", v), units[u])
    }
    static func eta(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite else { return "—" }
        if t < 60 { return "\(Int(t)) sec" }
        if t < 3600 { return "\(Int(t / 60)) min" }
        if t < 86400 { let h = t / 3600; return h < 10 ? String(format: "%.1f hrs", h) : "\(Int(h)) hrs" }
        return "\(Int(t / 86400)) days"
    }
    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    static func when(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

enum Link {
    static let fileExtensions: Set<String> = [
        "dmg", "pkg", "zip", "iso", "img", "torrent", "mp4", "mkv", "mov", "avi", "webm", "mp3", "flac",
        "wav", "m4a", "pdf", "epub", "7z", "rar", "tar", "gz", "tgz", "xz", "bz2", "zst", "exe", "msi",
        "deb", "rpm", "apk", "ipa", "bin", "xip", "jar", "csv", "parquet", "safetensors", "gguf",
    ]

    static func isMagnet(_ s: String) -> Bool { s.lowercased().hasPrefix("magnet:?") }

    static func isWebLink(_ s: String) -> Bool {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "sftp"].contains(scheme) && u.host != nil
    }

    /// Looks like food lying around: a magnet, or a link straight to a file.
    static func looksLikeCrumb(_ s: String) -> Bool {
        if isMagnet(s) { return true }
        guard isWebLink(s), let u = URL(string: s) else { return false }
        return fileExtensions.contains(u.pathExtension.lowercased())
    }
}
