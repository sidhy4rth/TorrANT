import Foundation
import Network

/// What uTorrent / qBittorrent do that aria2 doesn't do by itself:
///  · add well-known public trackers to every torrent, so a bare magnet finds people in seconds;
///  · listen on one fixed port, so the DHT (the trackerless peer network) remembers us;
///  · join the IPv6 DHT when the Mac has a public IPv6 address;
///  · ask the router to open that port (NAT-PMP, then UPnP), so people can connect *to* us,
///    not only us to them. Without an open door you reach roughly half of a swarm.
enum SwarmTuning {
    /// One port for TCP peers and the UDP DHT, chosen once and kept.
    static var port: Int {
        if let p = UserDefaults.standard.object(forKey: "btPort") as? Int, (1024...65535).contains(p) { return p }
        let p = Int.random(in: 20000...59000)
        UserDefaults.standard.set(p, forKey: "btPort")
        return p
    }

    /// A short, reliable fallback; the full list is refreshed from ngosang/trackerslist daily.
    static let builtIn = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.theoks.net:6969/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.qu.ax:6969/announce",
        "udp://tracker.dler.org:6969/announce",
        "http://tracker.opentrackr.org:1337/announce",
    ]

    static func trackersFile(_ support: URL) -> URL { support.appendingPathComponent("trackers.txt") }

    /// The list to start with: yesterday's download if there is one, else the built-in one.
    static func trackers(_ support: URL) -> [String] {
        let cached = (try? String(contentsOf: trackersFile(support), encoding: .utf8)).map(clean) ?? []
        return cached.count >= 5 ? cached : builtIn
    }

    /// Fresh list (at most once a day). Returns it when it changed.
    static func refreshTrackers(_ support: URL) async -> [String]? {
        let f = trackersFile(support)
        if let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(age) < 86_400 { return nil }
        guard let url = URL(string: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt"),
              let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: d, encoding: .utf8) else { return nil }
        let list = clean(text)
        guard list.count >= 5 else { return nil }
        try? list.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        return list
    }

    /// The big list (100+ trackers) for rescuing a stuck torrent; fetched on demand, kept a day.
    static func allTrackers(_ support: URL) async -> [String] {
        let f = support.appendingPathComponent("trackers-all.txt")
        if let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(age) < 86_400,
           let cached = try? String(contentsOf: f, encoding: .utf8), clean(cached).count > 20 { return clean(cached) }
        if let url = URL(string: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt"),
           let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200,
           let text = String(data: d, encoding: .utf8), clean(text).count > 20 {
            try? clean(text).joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
            return clean(text)
        }
        return trackers(support)
    }

    /// aria2 speaks UDP and HTTP(S) trackers only.
    private static func clean(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ($0.hasPrefix("udp://") || $0.hasPrefix("http://") || $0.hasPrefix("https://")) && !$0.contains(",") }
            .filter { seen.insert($0).inserted }
    }

    /// The Mac's public (global) IPv6 address, if it has one.
    static func globalIPv6() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let a = String(cString: host).split(separator: "%").first.map(String.init) ?? ""
            let lower = a.lowercased()
            // Global unicast starts with 2 or 3; skip link-local (fe80), private (fc/fd) and the odd tunnels.
            if lower.hasPrefix("2") || lower.hasPrefix("3") { found = a; break }
        }
        return found
    }

    /// The Mac's IPv4 address on the default network (what the router forwards to).
    static func localIPv4() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    static func gateway() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").first { $0.contains("gateway:") }?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
    }
}

/// Asks the router to forward TorrANT's port, so other people can connect in.
@MainActor @Observable
final class PortMapper {
    static let shared = PortMapper()

    enum Door: Equatable { case checking, open(String), closed }
    var door: Door = .checking

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var upnp: (control: URL, service: String)?

    func start(port: Int) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.map(port)
                try? await Task.sleep(for: .seconds(20 * 60))   // leases are an hour; renew well before
            }
        }
    }

    func stop(port: Int) {
        loop?.cancel()
        guard let gw = SwarmTuning.gateway() else { return }
        // Close the door on the way out.
        _ = PortMapper.natpmp(gateway: gw, port: port, tcp: true, lifetime: 0)
        _ = PortMapper.natpmp(gateway: gw, port: port, tcp: false, lifetime: 0)
        if let u = upnp {
            for proto in ["TCP", "UDP"] {
                PortMapper.soapSync(u.control, u.service, "DeletePortMapping",
                                    "<NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>\(proto)</NewProtocol>")
            }
        }
    }

    private func map(_ port: Int) async {
        let result: (String?, (URL, String)?) = await Task.detached(priority: .utility) {
            guard let gw = SwarmTuning.gateway() else { return (nil, nil) }
            if PortMapper.natpmp(gateway: gw, port: port, tcp: true, lifetime: 3600),
               PortMapper.natpmp(gateway: gw, port: port, tcp: false, lifetime: 3600) {
                return ("NAT-PMP", nil)
            }
            if let ip = SwarmTuning.localIPv4(), let igd = PortMapper.findIGD() {
                var ok = true
                for proto in ["TCP", "UDP"] {
                    var done = false
                    for lease in [3600, 0] where !done {   // some routers only accept permanent leases
                        done = PortMapper.soapSync(igd.0, igd.1, "AddPortMapping", """
                            <NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>\(proto)</NewProtocol>\
                            <NewInternalPort>\(port)</NewInternalPort><NewInternalClient>\(ip)</NewInternalClient><NewEnabled>1</NewEnabled>\
                            <NewPortMappingDescription>TorrANT</NewPortMappingDescription><NewLeaseDuration>\(lease)</NewLeaseDuration>
                            """)
                    }
                    ok = ok && done
                }
                if ok { return ("UPnP", igd) }
            }
            return (nil, nil)
        }.value
        if let igd = result.1 { upnp = (igd.0, igd.1) }
        door = result.0.map { .open($0) } ?? .closed
    }

    // MARK: NAT-PMP (RFC 6886): one small UDP request to the router.

    nonisolated static func natpmp(gateway: String, port: Int, tcp: Bool, lifetime: UInt32) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(5351).bigEndian
        inet_pton(AF_INET, gateway, &addr.sin_addr)
        let p = UInt16(port)
        var req: [UInt8] = [0, tcp ? 2 : 1, 0, 0, UInt8(p >> 8), UInt8(p & 0xff), UInt8(p >> 8), UInt8(p & 0xff)]
        req += [UInt8(lifetime >> 24), UInt8((lifetime >> 16) & 0xff), UInt8((lifetime >> 8) & 0xff), UInt8(lifetime & 0xff)]
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, req, req.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sent == req.count else { return false }
        var buf = [UInt8](repeating: 0, count: 16)
        let n = recv(fd, &buf, buf.count, 0)
        return n >= 16 && buf[1] == (tcp ? 130 : 129) && buf[2] == 0 && buf[3] == 0
    }

    // MARK: UPnP IGD: find the router over SSDP, then ask it to forward the port.

    nonisolated static func findIGD() -> (URL, String)? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &addr.sin_addr)
        let msg = Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n".utf8)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        let reply = String(decoding: buf[0..<n], as: UTF8.self)
        guard let loc = reply.split(whereSeparator: \.isNewline)
                .first(where: { $0.lowercased().hasPrefix("location:") })?
                .dropFirst("location:".count).trimmingCharacters(in: .whitespaces),
              let locURL = URL(string: loc),
              let xml = try? String(contentsOf: locURL, encoding: .utf8) else { return nil }
        for service in ["urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANIPConnection:1",
                        "urn:schemas-upnp-org:service:WANPPPConnection:1"] {
            guard let r = xml.range(of: "<serviceType>\(service)</serviceType>"),
                  let c0 = xml.range(of: "<controlURL>", range: r.upperBound..<xml.endIndex),
                  let c1 = xml.range(of: "</controlURL>", range: c0.upperBound..<xml.endIndex),
                  let control = URL(string: String(xml[c0.upperBound..<c1.lowerBound]), relativeTo: locURL)?.absoluteURL
            else { continue }
            return (control, service)
        }
        return nil
    }

    @discardableResult
    nonisolated static func soapSync(_ control: URL, _ service: String, _ action: String, _ args: String) -> Bool {
        var req = URLRequest(url: control, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data("""
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
            <s:Body><u:\(action) xmlns:u="\(service)">\(args)</u:\(action)></s:Body></s:Envelope>
            """.utf8)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, r, _ in
            ok = (r as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return ok
    }
}
