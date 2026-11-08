import SwiftUI
import AppKit

// MARK: - Where you stopped

/// Remembers how far you got in every video (by file name), from VLC's own reports.
@MainActor @Observable
final class WatchLog {
    static let shared = WatchLog()

    struct Spot: Codable, Equatable {
        var at: Double
        var length: Double
        var when: Date
    }

    var spots: [String: Spot] = [:]
    @ObservationIgnored private var savedAt = Date.distantPast

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT/watched.json")
    }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([String: Spot].self, from: d) { spots = s }
    }

    func note(file name: String, at: Double, of length: Double) {
        guard length > 60, at >= 0 else { return }
        spots[name] = Spot(at: at, length: length, when: Date())
        if Date().timeIntervalSince(savedAt) > 10 { save() }
    }

    func save() {
        savedAt = Date()
        if let d = try? JSONEncoder().encode(spots) { try? d.write(to: file, options: .atomic) }
    }

    func fraction(_ name: String) -> Double {
        guard let s = spots[name], s.length > 0 else { return 0 }
        return min(1, s.at / s.length)
    }

    func finished(_ name: String) -> Bool {
        guard let s = spots[name] else { return false }
        return s.at / s.length >= 0.95 || s.length - s.at < 90
    }

    /// Where to pick up: a few seconds before you stopped, unless you'd barely started or finished.
    func resumeAt(_ name: String) -> Double? {
        guard let s = spots[name], s.at > 30, !finished(name) else { return nil }
        return max(0, s.at - 5)
    }

    func minutesLeft(_ name: String) -> Int? {
        guard let s = spots[name] else { return nil }
        return max(1, Int((s.length - s.at) / 60))
    }

    /// In a season: the episode you were in the middle of, or the one after the last you finished.
    func nextUp(in eps: [URL]) -> URL? {
        guard let last = eps.enumerated()
            .filter({ spots[$0.element.lastPathComponent] != nil })
            .max(by: { spots[$0.element.lastPathComponent]!.when < spots[$1.element.lastPathComponent]!.when })
        else { return nil }
        if !finished(last.element.lastPathComponent) { return last.element }
        return last.offset + 1 < eps.count ? eps[last.offset + 1] : nil
    }
}

// MARK: - What's in the Library

struct LibraryEntry: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let isShow: Bool
    /// Cleaned from the file name; stays put so posters and names stay matched to it.
    let parsed: String
    let year: Int?
    let season: Int?
    let episodes: [URL]
    /// What's shown: the proper name once Wikipedia / TVmaze found one.
    var title: String
    var posterKey: String { isShow ? "show:\(parsed.lowercased())" : "movie:\(parsed.lowercased()):\(year ?? 0)" }

    init(url: URL, isShow: Bool, title: String, year: Int?, season: Int?, episodes: [URL]) {
        self.url = url; self.isShow = isShow; self.parsed = title; self.title = title
        self.year = year; self.season = season; self.episodes = episodes
    }
}

enum Titles {
    /// "The.Invite.2026.1080p.10bit.BluRay…" → ("The Invite", 2026, nil, nil)
    /// "Campus.Drivers.S01E03.1080p…" → ("Campus Drivers", nil, 1, 3)
    static func parse(_ raw: String) -> (title: String, year: Int?, season: Int?, episode: Int?) {
        var s = raw
        if let dot = s.range(of: #"\.(mkv|mp4|m4v|avi|mov|webm|ts|wmv|flv)$"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(dot)
        }
        s = s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        var cut = s.endIndex
        var year: Int?, season: Int?, episode: Int?
        if let m = s.range(of: #"(?i)\bS(\d{1,2})(E(\d{1,3}))?\b"#, options: .regularExpression) {
            let tag = s[m].uppercased().dropFirst()
            let parts = tag.split(separator: "E")
            season = Int(parts.first ?? "")
            if parts.count > 1 { episode = Int(parts[1]) }
            cut = min(cut, m.lowerBound)
        }
        if let m = s.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression), m.lowerBound > s.startIndex {
            year = Int(s[m]); cut = min(cut, m.lowerBound)
        }
        if let m = s.range(of: #"(?i)\b(2160p|1080p|720p|480p|4k|web[- ]?dl|webrip|bluray|brrip|hdrip|x264|x265|hevc)\b"#, options: .regularExpression) {
            cut = min(cut, m.lowerBound)
        }
        let title = s[..<cut].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-[](")))
        return (title.isEmpty ? raw : title, year, season, episode)
    }
}

@MainActor @Observable
final class LibraryStore {
    static let shared = LibraryStore()

    var entries: [LibraryEntry] = []
    var posters: [String: URL] = [:]      // poster key → image on disk
    var scanned = false

    @ObservationIgnored private var tried: [String: String] = [:]   // key → file name, "" if none found
    @ObservationIgnored private var names: [String: String] = [:]   // key → proper title
    @ObservationIgnored private var fetching = false

    private var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT/posters", isDirectory: true)
    }
    private var index: URL { dir.appendingPathComponent("posters.json") }
    private var namesFile: URL { dir.appendingPathComponent("names.json") }

    init() {
        if let d = try? Data(contentsOf: index), let t = try? JSONDecoder().decode([String: String].self, from: d) {
            tried = t
            for (k, f) in t where !f.isEmpty { posters[k] = dir.appendingPathComponent(f) }
        }
        if let d = try? Data(contentsOf: namesFile), let n = try? JSONDecoder().decode([String: String].self, from: d) { names = n }
    }

    var movies: [LibraryEntry] { entries.filter { !$0.isShow } }
    var shows: [LibraryEntry] { entries.filter(\.isShow) }

    /// Episodes and movies you're part-way through, newest first.
    var continueWatching: [(entry: LibraryEntry, file: URL)] {
        let log = WatchLog.shared
        var out: [(LibraryEntry, URL, Date)] = []
        for e in entries {
            let files = e.isShow ? e.episodes : [e.url]
            if e.isShow {
                if let next = log.nextUp(in: files), let when = files.compactMap({ log.spots[$0.lastPathComponent]?.when }).max() {
                    out.append((e, next, when))
                }
            } else if let s = log.spots[e.url.lastPathComponent], log.resumeAt(e.url.lastPathComponent) != nil {
                out.append((e, e.url, s.when))
            }
        }
        return out.sorted { $0.2 > $1.2 }.prefix(12).map { ($0.0, $0.1) }
    }

    func refresh() async {
        guard let root = Colony.shared.driveDir else { entries = []; scanned = true; return }
        var found = await Task.detached(priority: .utility) { LibraryStore.scan(root) }.value
        for i in found.indices { if let n = names[found[i].posterKey] { found[i].title = n } }
        if found != entries { entries = found }
        scanned = true
        await fetchPosters()
    }

    nonisolated static func scan(_ root: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var out: [LibraryEntry] = []
        for u in top {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let p = Titles.parse(u.lastPathComponent)
            if isDir {
                let eps = Streamer.episodes(in: u)
                guard !eps.isEmpty else { continue }
                let show = p.season != nil || eps.count > 1
                out.append(LibraryEntry(url: u, isShow: show, title: p.title, year: p.year, season: p.season ?? 1,
                                        episodes: show ? eps : []))
            } else if Streamer.isVideo(u) {
                out.append(LibraryEntry(url: u, isShow: false, title: p.title, year: p.year, season: nil, episodes: []))
            }
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: Posters (Wikipedia for films, TVmaze for shows; both free, no account)

    private func fetchPosters() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for e in entries where tried[e.posterKey] == nil {
            let (img, name) = await LibraryStore.lookUp(e)
            var saved = ""
            if let img, let data = await LibraryStore.download(img) {
                let f = "\(abs(e.posterKey.hashValue)).img"
                if (try? data.write(to: dir.appendingPathComponent(f), options: .atomic)) != nil {
                    saved = f
                    posters[e.posterKey] = dir.appendingPathComponent(f)
                }
            }
            if let name, !name.isEmpty {
                names[e.posterKey] = name
                if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i].title = name }
                if let d = try? JSONEncoder().encode(names) { try? d.write(to: namesFile, options: .atomic) }
            }
            tried[e.posterKey] = saved
            if let d = try? JSONEncoder().encode(tried) { try? d.write(to: index, options: .atomic) }
        }
    }

    nonisolated private static func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("TorrANT/0.2 (personal macOS app)", forHTTPHeaderField: "User-Agent")
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    nonisolated private static func download(_ url: URL) async -> Data? { await get(url) }

    nonisolated private static func json(_ s: String) async -> Any? {
        guard let u = URL(string: s), let d = await get(u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    nonisolated private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))) ?? s
    }

    /// Poster image and a nicer display name, if found.
    nonisolated static func lookUp(_ e: LibraryEntry) async -> (URL?, String?) {
        if e.isShow, let d = await json("https://api.tvmaze.com/singlesearch/shows?q=\(q(e.title))") as? [String: Any] {
            let img = (d["image"] as? [String: Any]).flatMap { ($0["original"] ?? $0["medium"]) as? String }
            if let img, let u = URL(string: img) { return (u, d["name"] as? String) }
        }
        let what = e.isShow ? "\(e.title) TV series" : "\(e.title) \(e.year.map(String.init) ?? "") film"
        guard let s = await json("https://en.wikipedia.org/w/api.php?action=query&list=search&srlimit=1&format=json&srsearch=\(q(what))") as? [String: Any],
              let hits = (s["query"] as? [String: Any])?["search"] as? [[String: Any]],
              let page = hits.first?["title"] as? String,
              let sum = await json("https://en.wikipedia.org/api/rest_v1/page/summary/\(q(page.replacingOccurrences(of: " ", with: "_")))") as? [String: Any]
        else { return (nil, nil) }
        let img = ((sum["thumbnail"] as? [String: Any])?["source"] ?? (sum["originalimage"] as? [String: Any])?["source"]) as? String
        // "Moana (2026 film)" → "Moana"
        let clean = page.replacingOccurrences(of: #"\s*\((\d{4} )?(film|TV series|miniseries)\)$"#, with: "", options: .regularExpression)
        return (img.flatMap(URL.init(string:)), e.isShow ? nil : clean)
    }
}

// MARK: - The Library window

struct LibraryView: View {
    @State private var store = LibraryStore.shared
    @State private var log = WatchLog.shared
    @State private var openShow: LibraryEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            if Colony.shared.driveDir == nil {
                empty("Google Drive isn't set up.", "Install Google Drive for desktop and sign in.")
            } else if store.entries.isEmpty {
                empty(store.scanned ? "Nothing in the Library yet." : "Opening the Library…",
                      "Things you send to Google Drive show up here, ready to stream.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        let cont = store.continueWatching
                        if !cont.isEmpty {
                            section("Continue watching")
                            ScrollView(.horizontal) {
                                HStack(spacing: 14) {
                                    ForEach(cont, id: \.file) { c in ContinueCard(entry: c.entry, file: c.file) }
                                }
                                .padding(.horizontal, 2)
                            }
                            .scrollIndicators(.never)
                        }
                        if !store.movies.isEmpty {
                            section("Movies")
                            grid(store.movies)
                        }
                        if !store.shows.isEmpty {
                            section("Shows")
                            grid(store.shows)
                        }
                    }
                    .padding(22)
                }
                .scrollIndicators(.never)
            }
        }
        .background(SoilBackground().ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
        .task { await store.refresh() }
        .sheet(item: $openShow) { s in EpisodesSheet(entry: s) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle.fill").font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.red)
            Text("Library").font(Theme.display(24))
            Text("Everything in your Drive, ready to stream.").font(Theme.body(14)).foregroundStyle(Theme.muted)
                .lineLimit(1).layoutPriority(-1)
            Spacer()
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            }
            .buttonStyle(.plain)
            .help("Look for new things in Drive")
        }
        .padding(.leading, 22)
        .padding(.trailing, 18)
        .frame(height: 54)
        .background(Theme.deep)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.surface2).frame(height: 1) }
    }

    private func section(_ t: String) -> some View {
        Text(t).font(Theme.display(22))
    }

    private func grid(_ items: [LibraryEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 200), spacing: 18, alignment: .top)],
                  alignment: .leading, spacing: 22) {
            ForEach(items) { e in
                PosterCard(entry: e) {
                    if e.isShow { openShow = e } else { Task { await Streamer.shared.play(e.url) } }
                }
            }
        }
    }

    private func empty(_ t: String, _ sub: String) -> some View {
        VStack(spacing: 14) {
            AntSketch(pose: .rest).frame(width: 260)
            Text(t).font(Theme.display(24))
            Text(sub).font(Theme.body(15)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The poster, or a drawn stand-in while it loads or if none was found.
struct PosterImage: View {
    let entry: LibraryEntry
    @State private var store = LibraryStore.shared
    var body: some View {
        ZStack {
            if let u = store.posters[entry.posterKey], let img = NSImage(contentsOf: u) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Theme.surface2, Theme.surface], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Image(systemName: entry.isShow ? "tv" : "film").font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.lineSoft)
                    Text(entry.title).font(Theme.display(16)).multilineTextAlignment(.center)
                        .foregroundStyle(Theme.muted).padding(.horizontal, 10)
                }
            }
        }
        .clipped()
    }
}

private struct PosterCard: View {
    let entry: LibraryEntry
    let action: () -> Void
    @State private var hover = false
    @State private var log = WatchLog.shared

    private var progress: Double {
        entry.isShow ? 0 : log.fraction(entry.url.lastPathComponent)
    }
    private var subtitle: String {
        if entry.isShow {
            let n = entry.episodes.count
            let seen = entry.episodes.filter { log.finished($0.lastPathComponent) }.count
            return "Season \(entry.season ?? 1) · \(n) episodes" + (seen > 0 ? " · \(seen) watched" : "")
        }
        if log.finished(entry.url.lastPathComponent) { return "\(entry.year.map(String.init) ?? "") · Watched" }
        if let m = log.minutesLeft(entry.url.lastPathComponent), log.resumeAt(entry.url.lastPathComponent) != nil {
            return "\(entry.year.map(String.init) ?? "") · \(m) min left"
        }
        return entry.year.map(String.init) ?? "Movie"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(PosterImage(entry: entry))
                    .clipped()
                if hover {
                    Color.black.opacity(0.35)
                    Image(systemName: entry.isShow ? "list.bullet" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Theme.redFill))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if progress > 0.01 {
                    Bar(fraction: progress, color: Theme.red).frame(height: 4).padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hover ? Theme.red : Theme.line, lineWidth: hover ? 2 : 1))
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
            Text(entry.title).font(Theme.body(14, .semibold)).lineLimit(1)
            Text(subtitle).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .help(entry.isShow ? "Show episodes" : (log.resumeAt(entry.url.lastPathComponent) != nil ? "Resume" : "Play"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct ContinueCard: View {
    let entry: LibraryEntry
    let file: URL
    @State private var hover = false
    @State private var log = WatchLog.shared

    private var label: String {
        if entry.isShow, let i = entry.episodes.firstIndex(of: file) {
            let ep = Titles.parse(file.lastPathComponent).episode ?? (i + 1)
            return "S\(entry.season ?? 1) · E\(ep)"
        }
        return entry.year.map(String.init) ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(entry: entry).frame(width: 64, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).font(Theme.body(14, .semibold)).lineLimit(1)
                Text(label).font(Theme.body(12)).foregroundStyle(Theme.muted)
                Bar(fraction: log.fraction(file.lastPathComponent), color: Theme.red).frame(height: 5)
                Text(log.resumeAt(file.lastPathComponent) != nil ? "\(log.minutesLeft(file.lastPathComponent) ?? 0) min left" : "Next episode")
                    .font(Theme.body(12, .semibold)).foregroundStyle(Theme.red)
            }
            .frame(width: 170, alignment: .leading)
            Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(hover ? Theme.redFill : Theme.surface2))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hover ? Theme.surface2 : Theme.surface))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            Task {
                if entry.isShow { await Streamer.shared.playSeason(entry.url, from: file) }
                else { await Streamer.shared.play(file) }
            }
        }
        .help("Pick up where you left off")
    }
}

private struct EpisodesSheet: View {
    let entry: LibraryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var log = WatchLog.shared

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            PosterImage(entry: entry).frame(width: 180, height: 270)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(Theme.display(24))
                        Text("Season \(entry.season ?? 1) · \(entry.episodes.count) episodes")
                            .font(Theme.body(14)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Play") {
                        Task { await Streamer.shared.playSeason(entry.url) }
                        dismiss()
                    }
                    .buttonStyle(RedButtonStyle())
                    .help("Plays from the episode you're on")
                    Button("Close") { dismiss() }.buttonStyle(GhostButtonStyle())
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(entry.episodes.enumerated()), id: \.element) { i, ep in
                            EpisodeLine(number: Titles.parse(ep.lastPathComponent).episode ?? (i + 1), file: ep) {
                                Task { await Streamer.shared.playSeason(entry.url, from: ep) }
                                dismiss()
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(24)
        .frame(width: 760, height: 520)
        .background(Theme.soil)
        .foregroundStyle(Theme.text)
    }
}

private struct EpisodeLine: View {
    let number: Int
    let file: URL
    let play: () -> Void
    @State private var hover = false
    @State private var log = WatchLog.shared
    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").font(Theme.display(18)).foregroundStyle(Theme.muted).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text("Episode \(number)").font(Theme.body(14, .semibold))
                let f = log.fraction(file.lastPathComponent)
                if f > 0.01 { Bar(fraction: f, color: log.finished(file.lastPathComponent) ? Theme.safe : Theme.red).frame(height: 4) }
            }
            Spacer()
            Text(log.finished(file.lastPathComponent) ? "Watched"
                 : log.resumeAt(file.lastPathComponent) != nil ? "\(log.minutesLeft(file.lastPathComponent) ?? 0) min left" : "")
                .font(Theme.body(12)).foregroundStyle(Theme.muted)
            Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(hover ? Theme.redFill : Theme.surface2))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Theme.surface2 : Theme.surface))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: play)
    }
}
