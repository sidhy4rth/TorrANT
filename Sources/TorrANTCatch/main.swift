// torrant-catch: Brave's native-messaging helper for the TorrANT extension.
// Brave starts it, writes length-prefixed JSON to stdin, and reads replies
// from stdout. Each message is passed to the running TorrANT app over a
// private Unix socket. If the app isn't running, we say so and Brave keeps
// the download.

import Foundation

let socketPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("TorrANT/catch.sock").path

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        guard let chunk = try? FileHandle.standardInput.read(upToCount: count - data.count),
              !chunk.isEmpty else { return nil }
        data.append(chunk)
    }
    return data
}

func reply(_ obj: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var len = UInt32(body.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &len, count: 4))
    FileHandle.standardOutput.write(body)
}

/// Sends one JSON line to the app and returns its one-line JSON reply.
func askApp(_ message: Data) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var tv = timeval(tv_sec: 7, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard ok == 0 else { return nil }

    var out = message
    out.append(0x0A)
    let sent = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
    guard sent == out.count else { return nil }

    var answer = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while !answer.contains(0x0A) {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        answer.append(contentsOf: buf[0..<n])
    }
    let line = answer.split(separator: 0x0A).first ?? Data()
    return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
}

while let header = readExactly(4) {
    let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    guard length > 0, length < 4 * 1024 * 1024, let body = readExactly(length) else { break }
    guard (try? JSONSerialization.jsonObject(with: body)) is [String: Any] else {
        reply(["ok": false, "reason": "bad message"])
        continue
    }
    if let answer = askApp(body) {
        reply(answer)
    } else {
        reply(["ok": false, "reason": "TorrANT isn't running"])
    }
}
