import Foundation

/// The name and total size inside a .torrent file, read straight from its bencoded bytes.
enum TorrentInfo {
    static func parse(_ data: Data) -> (name: String, size: Int64)? {
        // Latin-1 maps every byte to one character, so byte offsets and string offsets match.
        guard data.first == UInt8(ascii: "d"), let s = String(data: data, encoding: .isoLatin1),
              let info = s.range(of: "4:info") else { return nil }
        var name = "Torrent"
        if let key = s.range(of: "4:name", range: info.upperBound..<s.endIndex) {
            var i = key.upperBound
            var digits = ""
            while i < s.endIndex, let d = s[i].wholeNumberValue { digits.append(String(d)); i = s.index(after: i) }
            if let len = Int(digits), i < s.endIndex, s[i] == ":" {
                let start = s.index(after: i)
                if let end = s.index(start, offsetBy: len, limitedBy: s.endIndex) {
                    let raw = String(s[start..<end]).data(using: .isoLatin1) ?? Data()
                    name = String(data: raw, encoding: .utf8) ?? String(s[start..<end])
                }
            }
        }
        var size: Int64 = 0
        if let re = try? NSRegularExpression(pattern: "6:lengthi(\\d+)e") {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 1), in: s) { size += Int64(s[r]) ?? 0 }
            }
        }
        return (name, size)
    }
}
