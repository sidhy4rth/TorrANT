import CryptoKit
import Foundation

/// "How many people have this?" before downloading: asks trackers for a torrent's seeders
/// (a UDP "scrape", BEP 15) without joining the swarm. A few bytes each way.
enum Health {
    struct Result: Equatable { let seeders: Int; let leechers: Int }

    // MARK: Which torrent (its 20-byte info-hash)

    /// From a magnet: xt=urn:btih:<40 hex> or <32 base32>.
    static func hash(magnet: String) -> Data? {
        guard let c = URLComponents(string: magnet),
              let xt = c.queryItems?.first(where: { $0.name == "xt" })?.value?.lowercased(),
              xt.hasPrefix("urn:btih:") else { return nil }
        let h = String(xt.dropFirst("urn:btih:".count))
        if h.count == 40 { return hexData(h) }
        if h.count == 32 { return base32(h.uppercased()) }
        return nil
    }

    /// From aria2's "infoHash" (40 hex characters).
    static func hash(hex: String) -> Data? { hex.count == 40 ? hexData(hex.lowercased()) : nil }

    /// From a .torrent file: SHA-1 of the bencoded "info" dictionary, byte for byte.
    static func hash(torrent d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.first == UInt8(ascii: "d") else { return nil }
        var i = 1
        while i < b.count, b[i] != UInt8(ascii: "e") {
            guard let (key, afterKey) = readString(b, i) else { return nil }
            guard let end = skip(b, afterKey) else { return nil }
            if key == Array("info".utf8) { return Data(Insecure.SHA1.hash(data: Data(b[afterKey..<end]))) }
            i = end
        }
        return nil
    }

    /// Trackers named in a magnet (tr=) or a .torrent (announce / announce-list).
    static func trackers(magnet: String) -> [String] {
        URLComponents(string: magnet)?.queryItems?.filter { $0.name == "tr" }.compactMap(\.value) ?? []
    }

    static func trackers(torrent d: Data) -> [String] {
        guard let s = String(data: d, encoding: .isoLatin1),
              let re = try? NSRegularExpression(pattern: #"\d+:((?:udp|https?)://[^\s:]+:\d+(?:/[^\s]*?)?)(?=\d+:|e)"#) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }

    // MARK: Asking the trackers

    /// Asks up to 8 UDP trackers at once and keeps the best answer.
    static func check(_ hash: Data, trackers extra: [String]) async -> Result? {
        var seen = Set<String>()
        let list = (extra + SwarmTuning.builtIn).filter { $0.hasPrefix("udp://") && seen.insert($0).inserted }.prefix(8)
        return await withTaskGroup(of: Result?.self) { g in
            for t in list { g.addTask { scrape(t, hash) } }
            var best: Result?
            for await r in g {
                if let r, r.seeders > (best?.seeders ?? -1) { best = r }
            }
            return best
        }
    }

    /// One UDP tracker: connect (action 0), then scrape (action 2). Blocking, 3 s timeout.
    static func scrape(_ tracker: String, _ hash: Data) -> Result? {
        guard let u = URL(string: tracker), let host = u.host, let port = u.port else { return nil }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { return nil }

        func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
        func read32(_ b: [UInt8], _ o: Int) -> UInt32 { b[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }

        let tx1 = UInt32.random(in: 0...UInt32.max)
        let conn = be(UInt64(0x41727101980)) + be(UInt32(0)) + be(tx1)
        guard send(fd, conn, conn.count, 0) == conn.count else { return nil }
        var r1 = [UInt8](repeating: 0, count: 16)
        guard recv(fd, &r1, 16, 0) == 16, read32(r1, 0) == 0, read32(r1, 4) == tx1 else { return nil }

        let tx2 = UInt32.random(in: 0...UInt32.max)
        let req = Array(r1[8..<16]) + be(UInt32(2)) + be(tx2) + [UInt8](hash)
        guard send(fd, req, req.count, 0) == req.count else { return nil }
        var r2 = [UInt8](repeating: 0, count: 20)
        guard recv(fd, &r2, 20, 0) == 20, read32(r2, 0) == 2, read32(r2, 4) == tx2 else { return nil }
        return Result(seeders: Int(read32(r2, 8)), leechers: Int(read32(r2, 16)))
    }

    /// The verdict for a magnet, a link to a .torrent, or a saved .torrent file; nil for anything else.
    static func forLink(_ link: String) async -> String? {
        if link.lowercased().hasPrefix("magnet:") {
            guard let h = hash(magnet: link) else { return nil }
            return label(await check(h, trackers: trackers(magnet: link)))
        }
        guard let u = URL(string: link), u.pathExtension.lowercased() == "torrent" else { return nil }
        let data: Data?
        if u.isFileURL { data = try? Data(contentsOf: u) }
        else {
            var req = URLRequest(url: u, timeoutInterval: 10)
            req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
            data = (try? await URLSession.shared.data(for: req)).flatMap { $0.0.count < 5_000_000 ? $0.0 : nil }
        }
        guard let d = data, let h = hash(torrent: d) else { return nil }
        return label(await check(h, trackers: trackers(torrent: d)))
    }

    // MARK: Words

    /// Short, plain verdict, e.g. "🌱 85 seeders · should be fast".
    static func label(_ r: Result?) -> String {
        guard let r else { return "❔ couldn't check how many people have it" }
        switch r.seeders {
        case 0: return "💤 nobody has the whole file right now" + (r.leechers > 0 ? " (\(r.leechers) partial)" : "")
        case 1...4: return "🐢 \(r.seeders) seeder\(r.seeders == 1 ? "" : "s") · will be slow"
        case 5...19: return "🌿 \(r.seeders) seeders · should be OK"
        default: return "🌱 \(r.seeders) seeders · should be fast"
        }
    }

    // MARK: Bencode / encoding helpers

    private static func readString(_ b: [UInt8], _ i: Int) -> ([UInt8], Int)? {
        var j = i, n = 0
        while j < b.count, b[j] >= 48, b[j] <= 57 { n = n * 10 + Int(b[j] - 48); j += 1 }
        guard j < b.count, b[j] == UInt8(ascii: ":"), j + 1 + n <= b.count else { return nil }
        return (Array(b[(j + 1)..<(j + 1 + n)]), j + 1 + n)
    }

    /// Index just past the bencoded value starting at i.
    private static func skip(_ b: [UInt8], _ i: Int) -> Int? {
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "i"):
            guard let e = b[i...].firstIndex(of: UInt8(ascii: "e")) else { return nil }
            return e + 1
        case UInt8(ascii: "l"), UInt8(ascii: "d"):
            var j = i + 1
            while j < b.count, b[j] != UInt8(ascii: "e") { guard let n = skip(b, j) else { return nil }; j = n }
            return j < b.count ? j + 1 : nil
        default:
            return readString(b, i)?.1
        }
    }

    private static func hexData(_ h: String) -> Data? {
        var d = Data(); var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let v = UInt8(h[i..<j], radix: 16) else { return nil }
            d.append(v); i = j
        }
        return d
    }

    private static func base32(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in s {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx; bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xff)); bits -= 8 }
        }
        return out.count == 20 ? out : nil
    }
}
