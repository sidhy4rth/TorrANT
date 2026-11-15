import Foundation

/// What's in "TorrANT Library" on Google Drive, read from Google itself through rclone
/// (one listing, ~3.5 s for the whole folder) instead of the Google Drive app's folder on the Mac.
///
/// Why (15 Nov): the Drive app restarted big uploads from 0 after every network blip, kept a
/// hidden 36 GB cache, and showed finished films as "Name (1).mkv" while its own failed copy
/// held the real name. With this list, the Library, the Drive page, episodes and subtitles show
/// what Google actually has, under its real names, with the Drive app open, closed or gone.
///
/// Files keep the same URLs as before: `root` + their path in the folder. `root` is the
/// Drive app's folder when it's installed, otherwise a stand-in path of the same shape,
/// so Streamer.pathInDrive turns either into the right streaming link.
final class DriveIndex: @unchecked Sendable {
    static let shared = DriveIndex()

    struct Entry: Sendable {
        let path: String      // inside TorrANT Library, "Show/S01E01.mkv"
        let size: Int64
        let isDir: Bool
        let added: Date       // when it reached Drive
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var children: [String: [String]] = [:]   // folder path ("" = top) -> child paths
    private var _root: URL?
    private var _loaded = false
    private var _at = Date.distantPast

    var loaded: Bool { lock.withLock { _loaded } }
    var root: URL? { lock.withLock { _root } }
    var age: TimeInterval { Date().timeIntervalSince(lock.withLock { _at }) }

    /// The folder the Library's URLs live under when the Drive app isn't installed.
    static let standIn = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/CloudStorage/GoogleDrive-TorrANT/My Drive", isDirectory: true)
        .appendingPathComponent(Uploader.folder, isDirectory: true)

    /// Swaps in a fresh listing (rclone lsjson / operations/list items, recursive, with metadata).
    func load(_ list: [[String: Any]], root: URL) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: $0) ?? plain.date(from: $0) } }

        var e: [String: Entry] = [:]
        var kids: [String: [String]] = [:]
        for item in list {
            guard let path = item["Path"] as? String, !path.isEmpty else { continue }
            let meta = item["Metadata"] as? [String: Any]
            let added = date(meta?["btime"] as? String) ?? date(item["ModTime"] as? String) ?? .distantPast
            let size = (item["Size"] as? NSNumber)?.int64Value ?? 0
            e[path] = Entry(path: path, size: max(0, size), isDir: (item["IsDir"] as? Bool) == true, added: added)
            let parent = (path as NSString).deletingLastPathComponent
            kids[parent, default: []].append(path)
        }
        lock.withLock {
            entries = e; children = kids; _root = root.standardizedFileURL; _loaded = true; _at = Date()
        }
    }

    /// Path inside TorrANT Library for a URL under `root`, or nil if it's somewhere else.
    func relative(_ url: URL) -> String? {
        guard let r = root?.path else { return nil }
        let p = url.standardizedFileURL.path
        if p == r { return "" }
        guard p.hasPrefix(r + "/") else { return nil }
        return String(p.dropFirst(r.count + 1))
    }

    func url(_ rel: String) -> URL? {
        guard let r = root else { return nil }
        return rel.isEmpty ? r : r.appendingPathComponent(rel)
    }

    func entry(_ url: URL) -> Entry? {
        guard let rel = relative(url) else { return nil }
        return lock.withLock { entries[rel] }
    }

    /// Direct children of a folder (nil if the folder isn't one the list knows about).
    func list(_ folder: URL) -> [Entry]? {
        guard loaded, let rel = relative(folder) else { return nil }
        return lock.withLock {
            if !rel.isEmpty, entries[rel]?.isDir != true { return nil }
            return (children[rel] ?? []).compactMap { entries[$0] }
        }
    }

    /// Every file (not folder) anywhere under a folder.
    func files(under folder: URL) -> [Entry]? {
        guard loaded, let rel = relative(folder) else { return nil }
        return lock.withLock {
            if !rel.isEmpty, entries[rel]?.isDir != true { return nil }
            let prefix = rel.isEmpty ? "" : rel + "/"
            return entries.values.filter { !$0.isDir && $0.path.hasPrefix(prefix) }
        }
    }

    func names(in folder: URL) -> Set<String> {
        Set((list(folder) ?? []).map { ($0.path as NSString).lastPathComponent })
    }
}
