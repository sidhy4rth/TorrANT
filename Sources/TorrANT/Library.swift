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
    /// When it landed in the Library folder (newest first in "Recently shelved").
    var added: Date = .distantPast
    var posterKey: String { isShow ? "show:\(parsed.lowercased())" : "movie:\(parsed.lowercased()):\(year ?? 0)" }

    init(url: URL, isShow: Bool, title: String, year: Int?, season: Int?, episodes: [URL], added: Date = .distantPast) {
        self.url = url; self.isShow = isShow; self.parsed = title; self.title = title
        self.year = year; self.season = season; self.episodes = episodes; self.added = added
    }
}

enum Titles {
    /// What a release name says about quality: "1080p", "Hindi + English", "Subs", "HDR".
    static func tags(_ raw: String) -> [String] {
        let u = raw.uppercased()
        var out: [String] = []
        if u.range(of: #"2160P|\b4K\b|UHD"#, options: .regularExpression) != nil { out.append("4K") }
        else if let m = u.range(of: #"\b(1080|720|480)P\b"#, options: .regularExpression) { out.append(String(u[m]).lowercased()) }
        let names = ["HIN": "Hindi", "ENG": "English", "FRE": "French", "FRA": "French", "TAM": "Tamil", "TEL": "Telugu",
                     "KOR": "Korean", "JPN": "Japanese", "JAP": "Japanese", "SPA": "Spanish", "GER": "German", "ITA": "Italian",
                     "MAL": "Malayalam", "KAN": "Kannada", "BEN": "Bengali", "PUN": "Punjabi", "CHI": "Chinese"]
        if let m = u.range(of: #"\b([A-Z]{3})(-[A-Z]{3})+\b"#, options: .regularExpression) {
            let langs = u[m].split(separator: "-").compactMap { names[String($0)] }
            if langs.count >= 2 { out.append(langs.joined(separator: " + ")) }
        } else if u.contains("DUAL AUDIO") || u.contains("DUAL-AUDIO") {
            out.append("Dual audio")
        } else if u.contains("HINDI") {
            out.append("Hindi")
        }
        if u.range(of: #"\b(E|M)?SUBS?\b"#, options: .regularExpression) != nil { out.append("Subs") }
        if u.range(of: #"\bHDR(10)?\b|DOLBY.?VISION|\bDV\b"#, options: .regularExpression) != nil { out.append("HDR") }
        return out
    }

    /// "Marshals.S01E05.1080p.WEB-DL.mkv" → "Marshals · S01 E05"; "Moana.2026.1080p.mkv" → "Moana (2026)".
    static func pretty(_ raw: String) -> String {
        let p = parse(raw)
        guard !p.title.isEmpty else { return raw }
        if let s = p.season {
            return "\(p.title) · S\(String(format: "%02d", s))" + (p.episode.map { " E\(String(format: "%02d", $0))" } ?? "")
        }
        return p.title + (p.year.map { " (\($0))" } ?? "")
    }

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
    @ObservationIgnored private var missedAt: [String: Date] = [:]  // last failed look-up (this launch)
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

    /// ↻ in the Library: look again for titles that had no poster last time.
    func retryMissing() async {
        for (k, v) in tried where v.isEmpty { tried[k] = nil; names[k] = nil; missedAt[k] = nil }
        TitleInfo.shared.retryMisses()
        await refresh()
    }

    /// Screenshot mode (TORRANT_DEMO=1): free, openly licensed films instead of your own Library.
    static var demo: Bool { ProcessInfo.processInfo.environment["TORRANT_DEMO"] != nil }

    nonisolated static func demoEntries() -> [LibraryEntry] {
        let films: [(String, Int)] = [("Sintel", 2010), ("Tears of Steel", 2012), ("Big Buck Bunny", 2008), ("Cosmos Laundromat", 2015),
                                      ("Elephants Dream", 2006), ("Sprite Fright", 2021), ("Spring", 2019), ("Agent 327 Operation Barbershop", 2017),
                                      ("Caminandes Llamigos", 2016), ("Glass Half", 2015), ("Coffee Run", 2020), ("Charge", 2022)]
        let base = URL(fileURLWithPath: "/tmp/torrant-demo")
        return films.enumerated().map { i, f in
            LibraryEntry(url: base.appendingPathComponent("\(f.0).\(f.1).1080p.mkv"), isShow: false, title: f.0, year: f.1,
                         season: nil, episodes: [], added: Date().addingTimeInterval(Double(-i) * 3600))
        }
    }

    func refresh() async {
        if Self.demo {
            var found = Self.demoEntries()
            for i in found.indices { if let n = names[found[i].posterKey] { found[i].title = n } }
            if found != entries { entries = found }
            scanned = true
            await fetchPosters()
            await TitleInfo.shared.fetch(entries)
            return
        }
        guard let root = Colony.shared.driveDir else { entries = []; scanned = true; return }
        var found = await Task.detached(priority: .utility) { LibraryStore.scan(root) }.value
        for i in found.indices { if let n = names[found[i].posterKey] { found[i].title = n } }
        if found != entries { entries = found }
        scanned = true
        await fetchPosters()
        await TitleInfo.shared.fetch(entries)
    }

    nonisolated static func scan(_ root: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .addedToDirectoryDateKey, .creationDateKey]
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var out: [LibraryEntry] = []
        for u in top {
            let v = try? u.resourceValues(forKeys: keys)
            let isDir = v?.isDirectory == true
            let added = v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast
            let p = Titles.parse(u.lastPathComponent)
            if isDir {
                let eps = Streamer.episodes(in: u)
                guard !eps.isEmpty else { continue }
                let show = p.season != nil || eps.count > 1
                out.append(LibraryEntry(url: u, isShow: show, title: p.title, year: p.year, season: p.season ?? 1,
                                        episodes: show ? eps : [], added: added))
            } else if Streamer.isVideo(u) {
                out.append(LibraryEntry(url: u, isShow: false, title: p.title, year: p.year, season: nil, episodes: [], added: added))
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
        // New titles, plus ones that had no poster: those retry once per launch and then at most
        // hourly, since Wikipedia pages and posters often appear after a film's release.
        let due = entries.filter { e in
            guard let t = tried[e.posterKey] else { return true }
            return t.isEmpty && Date().timeIntervalSince(missedAt[e.posterKey] ?? .distantPast) > 3600
        }
        for e in due {
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
            if saved.isEmpty { missedAt[e.posterKey] = Date() }
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

    nonisolated static func json(_ s: String) async -> Any? {
        guard let u = URL(string: s), let d = await get(u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    nonisolated static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))) ?? s
    }

    /// Poster image and a nicer display name, if found.
    nonisolated static func lookUp(_ e: LibraryEntry) async -> (URL?, String?) {
        if e.isShow, let d = await json("https://api.tvmaze.com/singlesearch/shows?q=\(q(e.title))") as? [String: Any] {
            let img = (d["image"] as? [String: Any]).flatMap { ($0["original"] ?? $0["medium"]) as? String }
            if let img, let u = URL(string: img) { return (u, d["name"] as? String) }
        }
        guard let sum = await wikiPage(e, needImage: true),
              let img = ((sum["thumbnail"] as? [String: Any])?["source"] ?? (sum["originalimage"] as? [String: Any])?["source"]) as? String
        else { return (nil, nil) }
        // Keep your title unless Wikipedia's is the same name, just tidier ("Moana (2026 film)" → "Moana").
        let found = (sum["title"] as? String ?? e.parsed)
            .replacingOccurrences(of: #"\s*\((\d{4} )?(film|TV series|miniseries)\)$"#, with: "", options: .regularExpression)
        let name = LibraryStore.norm(found) == LibraryStore.norm(e.parsed) ? found : nil
        return (URL(string: img), e.isShow ? nil : name)
    }

    /// The Wikipedia page (its summary) for a film or show: checks likely pages and keeps the
    /// first that is a film/series from the right year (and has a poster, when asked). The top
    /// search hit alone was wrong for "Dalloway (2025)": it returned Mrs Dalloway (1997).
    nonisolated static func wikiPage(_ e: LibraryEntry, needImage: Bool) async -> [String: Any]? {
        let t = e.parsed
        var pages: [String] = e.isShow
            ? ["\(t) (TV series)", "\(t) (\(e.year.map(String.init) ?? "") TV series)", t]
            : (e.year.map { ["\(t) (\($0) film)"] } ?? []) + ["\(t) (film)", t]
        let what = e.isShow ? "\(t) TV series" : "\(t) \(e.year.map(String.init) ?? "") film"
        if let s = await json("https://en.wikipedia.org/w/api.php?action=query&list=search&srlimit=5&format=json&srsearch=\(q(what))") as? [String: Any],
           let hits = (s["query"] as? [String: Any])?["search"] as? [[String: Any]] {
            pages += hits.compactMap { $0["title"] as? String }
        }
        var seen = Set<String>()
        for page in pages where seen.insert(page).inserted {
            guard let sum = await json("https://en.wikipedia.org/api/rest_v1/page/summary/\(q(page.replacingOccurrences(of: " ", with: "_")))") as? [String: Any],
                  (sum["type"] as? String) == "standard",
                  !needImage || sum["thumbnail"] != nil || sum["originalimage"] != nil
            else { continue }
            let about = ((sum["description"] as? String ?? "") + " " + (sum["extract"] as? String ?? "")).lowercased()
            let kind = e.isShow ? (about.contains("series") || about.contains("television")) : about.contains("film")
            let rightYear = e.year.map { about.contains(String($0)) } ?? true
            guard kind, rightYear else { continue }
            return sum
        }
        return nil
    }
}

// MARK: - The Library window

struct LibraryView: View {
    @State private var store = LibraryStore.shared
    @State private var log = WatchLog.shared
    @State private var info = TitleInfo.shared
    @State private var openShow: LibraryEntry?
    @State private var openMovie: LibraryEntry?
    @State private var filter: Filter = .all
    @State private var sort: Sort = .recent
    @State private var query = ""

    enum Filter: String, CaseIterable { case all = "All", movies = "Movies", shows = "Shows", unwatched = "Unwatched" }
    enum Sort: String, CaseIterable { case recent = "Recently shelved", top = "Top rated", az = "A–Z" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if Colony.shared.driveDir == nil {
                empty("Google Drive isn't set up.", "Install Google Drive for desktop and sign in.")
            } else if store.entries.isEmpty {
                empty(store.scanned ? "Nothing in the Library yet." : "Opening the Library…",
                      "Things you send to Google Drive show up here, ready to stream.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        top
                        chips
                        let list = visible
                        if list.isEmpty {
                            Text("Nothing matches.").font(Theme.body(15)).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity).padding(.top, 30)
                        } else {
                            Shelves(entries: list, open: open, play: play)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 26)
                }
                .scrollIndicators(.never)
            }
        }
        .background(SoilBackground().ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .task { await store.refresh() }
        .sheet(item: $openShow) { s in EpisodesSheet(entry: s) }
        .sheet(item: $openMovie) { m in MovieSheet(entry: m) }
    }

    private func open(_ e: LibraryEntry) { if e.isShow { openShow = e } else { openMovie = e } }
    private func play(_ e: LibraryEntry) {
        Task { if e.isShow { await Streamer.shared.playSeason(e.url) } else { await Streamer.shared.play(e.url) } }
    }

    // MARK: Filtering and sorting

    private var visible: [LibraryEntry] {
        var list = store.entries
        switch filter {
        case .all: break
        case .movies: list = list.filter { !$0.isShow }
        case .shows: list = list.filter(\.isShow)
        case .unwatched:
            list = list.filter { e in e.isShow ? e.episodes.contains { !log.finished($0.lastPathComponent) } : !log.finished(e.url.lastPathComponent) }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(q) } }
        switch sort {
        case .recent: list.sort { $0.added > $1.added }
        case .top: list.sort { rating($0) > rating($1) }
        case .az: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return list
    }

    /// Any score as 0–100 so films (percent) and shows (out of 10) sort together.
    private func rating(_ e: LibraryEntry) -> Double {
        guard let s = info.details[e.posterKey]?.score else { return -1 }
        let digits = s.filter { $0.isNumber || $0 == "." }
        guard let v = Double(digits) else { return -1 }
        return s.contains("%") || v > 10 ? v : v * 10
    }

    // MARK: Top: the newest arrival, and what you were watching

    private var top: some View {
        let newest = store.entries.max { $0.added < $1.added }
        let cont = store.continueWatching
        return HStack(alignment: .top, spacing: 16) {
            if let n = newest {
                Spotlight(entry: n, shelfMates: Array(store.entries.filter { $0.id != n.id }.sorted { $0.added > $1.added }.prefix(2)),
                          open: { open(n) }, play: { play(n) })
            }
            if !cont.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Continue watching").font(Theme.display(17))
                    ForEach(cont.prefix(2), id: \.file) { c in ContinueCard(entry: c.entry, file: c.file) }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(width: 330, height: 236, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
            }
        }
        .frame(height: 236)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases, id: \.self) { f in
                chip(f.rawValue + count(f), on: filter == f) { filter = f }
            }
            Spacer()
            Text("Sort").font(Theme.body(13)).foregroundStyle(Theme.muted)
            ForEach(Sort.allCases, id: \.self) { s in
                chip(s.rawValue, on: sort == s, soft: true) { sort = s }
            }
        }
    }

    private func count(_ f: Filter) -> String {
        let n: Int
        switch f {
        case .all: n = store.entries.count
        case .movies: n = store.movies.count
        case .shows: n = store.shows.count
        case .unwatched: n = store.entries.filter { e in e.isShow ? e.episodes.contains { !log.finished($0.lastPathComponent) } : !log.finished(e.url.lastPathComponent) }.count
        }
        return " \(n)"
    }

    private func chip(_ t: String, on: Bool, soft: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { action() } } label: {
            Text(t).font(Theme.body(13, .bold))
                .foregroundStyle(on ? (soft ? Theme.softText : Theme.soil) : Theme.text)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(on ? (soft ? Theme.soft : Theme.text) : Theme.surface))
        }
        .buttonStyle(.plain)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text("Library").font(Theme.display(24))
            Text("\(store.entries.count) titles · everything streams from Drive").font(Theme.body(14)).foregroundStyle(Theme.muted)
                .lineLimit(1).layoutPriority(-1)
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                TextField("", text: $query, prompt: Text("Search your Library").foregroundColor(Theme.muted))
                    .textFieldStyle(.plain).font(Theme.body(14))
            }
            .padding(.horizontal, 14).frame(width: 280, height: 36)
            .background(Capsule().fill(Theme.surface))
            Button { Task { await store.retryMissing() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .help("Look for new things in Drive, and try again for missing posters")
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
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

/// Posters standing on shelves, a row per shelf; they rise in one after another.
private struct Shelves: View {
    let entries: [LibraryEntry]
    let open: (LibraryEntry) -> Void
    let play: (LibraryEntry) -> Void
    @State private var width: CGFloat = 1000
    private let gap: CGFloat = 18

    var body: some View {
        let cols = max(4, Int((width + gap) / (150 + gap)))
        let colW = (width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let rows = stride(from: 0, to: entries.count, by: cols).map { Array(entries[$0..<min($0 + cols, entries.count)]) }
        VStack(alignment: .leading, spacing: 26) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.track)
                        .frame(width: width, height: 8)
                        .offset(y: colW * 1.5 - 2)
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { i, e in
                            PosterCard(entry: e, order: r * cols + i) { open(e) } play: { play(e) }
                                .frame(width: colW)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
    }
}

/// "Just shelved": the newest arrival, with the librarian ant carrying its poster onto the shelf.
private struct Spotlight: View {
    let entry: LibraryEntry
    let shelfMates: [LibraryEntry]
    let open: () -> Void
    let play: () -> Void
    @State private var info = TitleInfo.shared
    @State private var log = WatchLog.shared

    var body: some View {
        let d = info.details[entry.posterKey]
        HStack(spacing: 0) {
            ShelvingScene(entry: entry, mates: shelfMates)
                .frame(width: 300)
            VStack(alignment: .leading, spacing: 9) {
                Text(entry.title).font(Theme.display(32)).lineLimit(1)
                HStack(spacing: 7) {
                    if let sc = d?.score {
                        Text(sc).font(Theme.body(12, .heavy)).foregroundStyle(Theme.soil)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(Theme.text))
                            .help(d?.scoreFrom ?? "")
                    }
                    if let y = entry.year { tag(String(y)) }
                    if entry.isShow { tag("Season \(entry.season ?? 1) · \(entry.episodes.count) episodes") }
                    if let a = d?.about { Text(a).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Text(d.map { $0.synopsis.isEmpty ? "No summary found yet." : $0.synopsis } ?? "Looking up what it's about…")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Button(entry.isShow ? "Play" : (log.resumeAt(entry.url.lastPathComponent) != nil ? "Resume" : "Play"), action: play)
                        .buttonStyle(RedButtonStyle())
                    Button("Details", action: open).buttonStyle(GhostButtonStyle())
                    StarPicker(key: entry.posterKey)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 236)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(Theme.body(12, .semibold)).padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface2))
    }
}

/// The librarian ant walks the newest poster over and lifts it onto the shelf (8 s, twice,
/// then rests; hover to watch again). Drawn in one Canvas so it stays smooth.
private struct ShelvingScene: View {
    let entry: LibraryEntry
    let mates: [LibraryEntry]
    @State private var start = Date()
    @State private var playing = true
    @State private var store = LibraryStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !playing || reduce)) { tl in
            Canvas { ctx, size in draw(&ctx, size, tl.date) }
        }
        .background(Theme.soil.opacity(0.55))
        .overlay(alignment: .topLeading) {
            Text("JUST SHELVED").font(Theme.body(11, .bold)).tracking(1.4).foregroundStyle(Theme.librarianAnt).padding(14)
        }
        .onHover { h in if h && !playing { replay() } }
        .onAppear { replay() }
        .onChange(of: entry.id) { _, _ in replay() }
    }

    private func replay() {
        start = Date(); playing = true
        Task { try? await Task.sleep(for: .seconds(16)); if Date().timeIntervalSince(start) >= 15.9 { playing = false } }
    }

    private func ease(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private func poster(_ ctx: inout GraphicsContext, _ e: LibraryEntry?, _ r: CGRect, alpha: Double = 1) {
        var g = ctx
        g.opacity = alpha
        let clip = Path(roundedRect: r, cornerRadius: 3)
        g.clip(to: clip)
        if let e, let u = store.posters[e.posterKey], let img = PosterCache.image(u) {
            g.draw(Image(nsImage: img).resizable(), in: r)
        } else {
            g.fill(clip, with: .color(Theme.surface2))
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ now: Date) {
        let floorY: CGFloat = 170
        let shelfY: CGFloat = 108
        // Shelf on the wall, with the last two arrivals already on it.
        ctx.fill(Path(roundedRect: CGRect(x: 168, y: shelfY, width: 118, height: 7), cornerRadius: 3), with: .color(Theme.track))
        for (i, m) in mates.prefix(2).enumerated() {
            poster(&ctx, m, CGRect(x: 234 + CGFloat(i) * 28, y: shelfY - 36, width: 24, height: 36))
        }
        ctx.fill(Path(CGRect(x: 0, y: floorY, width: size.width, height: 3)), with: .color(Theme.track))

        let u = (playing && !reduce) ? (now.timeIntervalSince(start) / 8).truncatingRemainder(dividingBy: 1) : 0.6
        // Ant: walks in, stops under the shelf, turns, walks home.
        let antX: Double
        if u < 0.4 { antX = lerp(28, 150, ease(u / 0.4)) }
        else if u < 0.58 { antX = 150 }
        else if u < 0.92 { antX = lerp(150, 28, ease((u - 0.58) / 0.34)) }
        else { antX = 28 }
        let facing: Double
        if u < 0.555 { facing = 1 }
        else if u < 0.575 { facing = 1 - 2 * (u - 0.555) / 0.02 }
        else if u < 0.94 { facing = -1 }
        else if u < 0.96 { facing = -1 + 2 * (u - 0.94) / 0.02 }
        else { facing = 1 }
        let walking = playing && !reduce && (u < 0.4 || (u > 0.58 && u < 0.92))
        var g = ctx
        g.scaleBy(x: 2, y: 2)
        RelayAnt.draw(&g, x: antX / 2, base: floorY / 2, color: Theme.librarianAnt, facing: abs(facing) < 0.05 ? 0.05 : facing,
                      alpha: 1, legs: walking ? now.timeIntervalSinceReferenceDate : nil)

        // The poster: on the ant's back, then up in an arc onto the shelf.
        let back = RelayAnt.back(x: antX / 2, base: floorY / 2, facing: 1)
        let carry = CGRect(x: back.x * 2 - 9, y: back.y * 2 - 22, width: 18, height: 27)
        let slot = CGRect(x: 204, y: shelfY - 36, width: 24, height: 36)
        var r = carry
        var alpha = 1.0
        if u < 0.4 {
            alpha = min(1, u / 0.03)
        } else if u < 0.55 {
            let k = ease((u - 0.4) / 0.15)
            let lift = sin(Double.pi * k) * 40
            r = CGRect(x: lerp(carry.minX, slot.minX, k), y: lerp(carry.minY, slot.minY, k) - lift,
                       width: lerp(carry.width, slot.width, k), height: lerp(carry.height, slot.height, k))
        } else {
            r = slot
            alpha = u > 0.94 && playing ? max(0, 1 - (u - 0.94) / 0.05) : 1
        }
        poster(&ctx, entry, r, alpha: alpha)
        // A soft ring where it lands.
        if u > 0.53 && u < 0.66 && playing {
            let k = (u - 0.53) / 0.13
            let ring = slot.insetBy(dx: -6 - 10 * k, dy: -6 - 10 * k)
            ctx.stroke(Path(roundedRect: ring, cornerRadius: 6), with: .color(Theme.librarianAnt.opacity(1 - k)), lineWidth: 2)
        }
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
    var order: Int = 0
    let action: () -> Void
    let play: () -> Void
    @State private var hover = false
    @State private var shown = false
    @State private var log = WatchLog.shared
    @State private var info = TitleInfo.shared

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
    private var stars: String? {
        info.mine[entry.posterKey].map { String(repeating: "★", count: $0) }
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
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Theme.redFill))
                        .contentShape(Circle())
                        .onTapGesture(perform: play)
                        .help(entry.isShow ? "Play from the episode you're on" : "Play now")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if progress > 0.01 {
                    Bar(fraction: progress, color: Theme.red).frame(height: 4).padding(8)
                }
            }
            .overlay(alignment: .topLeading) { ScoreBadge(entry: entry) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hover ? Theme.red : Theme.line, lineWidth: hover ? 2 : 1))
            .scaleEffect(hover ? 1.045 : 1)
            .offset(y: hover ? -7 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hover)
            Text(entry.title).font(Theme.body(14, .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Text(subtitle).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                if let stars { Text(stars).font(Theme.body(11)).foregroundStyle(Theme.red).lineLimit(1) }
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .help(info.details[entry.posterKey]?.synopsis.nilIfEmpty ?? (entry.isShow ? "Show episodes" : "What it's about"))
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 16)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(Double(min(order, 24)) * 0.035)) { shown = true }
        }
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
                .foregroundStyle(hover ? Theme.onAccent : Theme.text)
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
                        Text(entry.title).font(Theme.display(24)).lineLimit(1)
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
                AboutBlock(entry: entry)
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
        .frame(width: 780, height: 600)
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
                .foregroundStyle(hover ? Theme.onAccent : Theme.text)
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

// MARK: - "You already have this"

extension LibraryStore {
    nonisolated static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// What you already have that matches a download's name: the same film (and year), the same
    /// season, or the same episode, in Drive or still on this Mac. Nil when it's new or isn't a
    /// film or show name (a name needs a year or a season number to be compared).
    func alreadyHave(_ name: String) async -> String? {
        if !scanned { await refresh() }
        let p = Titles.parse(name)
        guard p.year != nil || p.season != nil else { return nil }
        let key = LibraryStore.norm(p.title)
        guard key.count >= 2 else { return nil }

        for e in entries where LibraryStore.norm(e.parsed) == key || LibraryStore.norm(e.title) == key {
            if let s = p.season {
                guard e.isShow, (e.season ?? 1) == s else { continue }
                if let ep = p.episode {
                    if e.episodes.contains(where: { Titles.parse($0.lastPathComponent).episode == ep }) {
                        return "\(e.title) S\(s) E\(ep), in your Library"
                    }
                    continue
                }
                return "\(e.title) Season \(s), in your Library"
            } else if !e.isShow, p.year == nil || e.year == nil || p.year == e.year {
                return e.title + (e.year.map { " (\($0))" } ?? "") + ", in your Library"
            }
        }
        // Finished downloads still on this Mac.
        for h in Colony.shared.hill where FileManager.default.fileExists(atPath: h.path) {
            let q = Titles.parse(h.name)
            guard LibraryStore.norm(q.title) == key else { continue }
            if p.season != nil {
                if q.season == p.season && (p.episode == nil || q.episode == nil || q.episode == p.episode) {
                    return "\(q.title) on this Mac"
                }
            } else if q.season == nil, p.year == nil || q.year == nil || p.year == q.year {
                return "\(q.title) on this Mac"
            }
        }
        return nil
    }
}

/// Poster images read once and kept, for views that redraw every frame.
@MainActor
enum PosterCache {
    private static var images: [URL: NSImage] = [:]
    static func image(_ u: URL) -> NSImage? {
        if let i = images[u] { return i }
        guard let i = NSImage(contentsOf: u) else { return nil }
        images[u] = i
        return i
    }
}
