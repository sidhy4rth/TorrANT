import SwiftUI

/// What a title is about and how good people say it is.
struct TitleDetails: Codable, Equatable {
    var synopsis = ""
    /// One line under the title: "2023 film by Christopher Nolan" or "Drama · Crime".
    var about: String?
    /// Short score for the poster badge ("IMDb 8.2", "🍅 93%", "★ 8.6") and where it's from.
    var score: String?
    var scoreFrom: String?
}

/// Scores, synopses and your own stars for everything in the Library. Free and without accounts:
/// films from Wikipedia (plot) and Wikidata (IMDb, Rotten Tomatoes, Metacritic), shows from TVmaze.
@MainActor @Observable
final class TitleInfo {
    static let shared = TitleInfo()

    var details: [String: TitleDetails] = [:]   // poster key → details
    var mine: [String: Int] = [:]               // poster key → your stars (1–5)

    @ObservationIgnored private var missedAt: [String: Date] = [:]
    @ObservationIgnored private var fetching = false

    private var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT/posters", isDirectory: true)
    }
    private var detailsFile: URL { dir.appendingPathComponent("details.json") }
    private var mineFile: URL { dir.appendingPathComponent("my-ratings.json") }

    init() {
        if let d = try? Data(contentsOf: detailsFile), let t = try? JSONDecoder().decode([String: TitleDetails].self, from: d) { details = t }
        if let d = try? Data(contentsOf: mineFile), let t = try? JSONDecoder().decode([String: Int].self, from: d) { mine = t }
    }

    /// Tap a star to rate; tap the same star again to clear it.
    func rate(_ key: String, _ stars: Int) {
        mine[key] = mine[key] == stars ? nil : stars
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(mine) { try? d.write(to: mineFile, options: .atomic) }
    }

    /// Looks up titles it doesn't know yet. Misses try again at most hourly.
    func fetch(_ entries: [LibraryEntry]) async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        var seen = Set<String>()
        for e in entries where seen.insert(e.posterKey).inserted && details[e.posterKey] == nil {
            guard Date().timeIntervalSince(missedAt[e.posterKey] ?? .distantPast) > 3600 else { continue }
            if let d = await TitleInfo.lookUp(e), !d.synopsis.isEmpty || d.score != nil {
                details[e.posterKey] = d
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(details) { try? data.write(to: detailsFile, options: .atomic) }
            } else {
                missedAt[e.posterKey] = Date()
            }
        }
    }

    func retryMisses() { missedAt = [:] }

    // MARK: Looking up

    nonisolated static func lookUp(_ e: LibraryEntry) async -> TitleDetails? {
        if e.isShow, let d = await LibraryStore.json("https://api.tvmaze.com/singlesearch/shows?q=\(LibraryStore.q(e.title))") as? [String: Any] {
            var out = TitleDetails()
            out.synopsis = short(plain(d["summary"] as? String ?? ""))
            let genres = d["genres"] as? [String] ?? []
            out.about = genres.isEmpty ? nil : genres.prefix(3).joined(separator: " · ")
            if let r = (d["rating"] as? [String: Any])?["average"] as? Double {
                out.score = String(format: "★ %.1f", r)
                out.scoreFrom = "TVmaze viewers"
            }
            if !out.synopsis.isEmpty { return out }
        }
        guard let sum = await LibraryStore.wikiPage(e, needImage: false) else { return nil }
        var out = TitleDetails()
        out.about = (sum["description"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let page = sum["title"] as? String ?? e.parsed
        let text = await pageText(page) ?? ""
        out.synopsis = short(match(text, #"\n==+ *(?:Premise|Synopsis|Plot summary|Plot|Story) *==+\n+([^\n]+)"#)
                             ?? (sum["extract"] as? String ?? ""))
        // Wikidata's IMDb score first; otherwise the page's own review section, which editors
        // keep fresher than Wikidata for new films; Wikidata's critics scores last.
        let listed = await (sum["wikibase_item"] as? String).asyncMap { await scores($0) } ?? [:]
        let tomatoes = match(text, #"Rotten Tomatoes[^\n]{0,250}?(\d{1,3})%"#).map { "\($0)%" } ?? listed["rt"]
        let meta = match(text, #"Metacritic[^\n]{0,250}?(\d{1,3}) out of 100"#) ?? listed["mc"]
        if let v = listed["imdb"] { (out.score, out.scoreFrom) = ("IMDb \(v)", "IMDb users") }
        else if let v = tomatoes { (out.score, out.scoreFrom) = ("🍅 \(v)", "Rotten Tomatoes critics") }
        else if let v = meta { (out.score, out.scoreFrom) = ("Metacritic \(v)", "Metacritic critics") }
        return out
    }

    /// A Wikipedia page as plain text.
    nonisolated static func pageText(_ page: String) async -> String? {
        guard let d = await LibraryStore.json("https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&redirects=1&format=json&titles=\(LibraryStore.q(page))") as? [String: Any],
              let pages = (d["query"] as? [String: Any])?["pages"] as? [String: Any] else { return nil }
        return (pages.values.first as? [String: Any])?["extract"] as? String
    }

    /// First capture group of a pattern, if it matches.
    nonisolated static func match(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Review scores on Wikidata, newest per site: "imdb" (8.2), "rt" (93%), "mc" (90).
    nonisolated static func scores(_ qid: String) async -> [String: String] {
        guard let d = await LibraryStore.json("https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=\(qid)&property=P444&format=json") as? [String: Any],
              let claims = (d["claims"] as? [String: Any])?["P444"] as? [[String: Any]] else { return [:] }
        let imdb = "Q37312", tomatoes = "Q105584", metacritic = "Q150248", tomatometer = "Q108403393"
        var best: [String: (value: String, when: String)] = [:]
        for c in claims {
            guard let v = ((c["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] as? String else { continue }
            let q = c["qualifiers"] as? [String: [[String: Any]]] ?? [:]
            func ids(_ p: String) -> [String] {
                (q[p] ?? []).compactMap { (($0["datavalue"] as? [String: Any])?["value"] as? [String: Any])?["id"] as? String }
            }
            let when = (q["P585"]?.first?["datavalue"] as? [String: Any]).flatMap { ($0["value"] as? [String: Any])?["time"] as? String } ?? ""
            guard let by = ids("P447").first else { continue }
            if by == tomatoes, !ids("P459").isEmpty, !ids("P459").contains(tomatometer) { continue }  // critics, not audience
            if best[by].map({ $0.when <= when }) ?? true { best[by] = (v, when) }
        }
        var out: [String: String] = [:]
        if let v = best[imdb]?.value, let n = v.split(separator: "/").first { out["imdb"] = String(n) }
        if let v = best[tomatoes]?.value { out["rt"] = v }
        if let v = best[metacritic]?.value, let n = v.split(separator: "/").first { out["mc"] = String(n) }
        return out
    }

    // MARK: Text

    /// "<p><b>Show</b> is…</p>" → "Show is…"
    nonisolated static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// The first two sentences, at most ~340 characters. Bits like "U." don't count as sentences.
    nonisolated static func short(_ s: String, sentences n: Int = 2, max: Int = 340) -> String {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: #"[^.!?]+(?:[.!?]+["”’)]?|$)\s*"#) else { return text }
        var out = "", count = 0
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let piece = String(text[r])
            if count >= n || (!out.isEmpty && out.count + piece.count > max) { break }
            out += piece
            if piece.trimmingCharacters(in: .whitespaces).count > 20 { count += 1 }
        }
        if out.isEmpty { out = String(text.prefix(max)) }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Views

/// The score in the poster's corner.
struct ScoreBadge: View {
    let entry: LibraryEntry
    @State private var info = TitleInfo.shared
    var body: some View {
        if let s = info.details[entry.posterKey]?.score {
            Text(s).font(Theme.body(11, .bold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.72)))
                .padding(7)
        }
    }
}

/// Your rating: five stars, tap the same one again to clear.
struct StarPicker: View {
    let key: String
    @State private var info = TitleInfo.shared
    @State private var hover: Int?
    var body: some View {
        let n = hover ?? info.mine[key] ?? 0
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= n ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(i <= n ? Theme.red : Theme.muted)
                    .contentShape(Rectangle())
                    .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
                    .onTapGesture { info.rate(key, i) }
                    .accessibilityLabel("\(i) star\(i == 1 ? "" : "s")")
                    .accessibilityAddTraits(.isButton)
            }
            Text(info.mine[key] == nil ? "Rate it" : "Your rating").font(Theme.body(12)).foregroundStyle(Theme.muted)
                .padding(.leading, 6)
        }
    }
}

/// Score, one-line description and synopsis, for the film and show sheets.
struct AboutBlock: View {
    let entry: LibraryEntry
    @State private var info = TitleInfo.shared
    var body: some View {
        let d = info.details[entry.posterKey]
        VStack(alignment: .leading, spacing: 10) {
            if let d, d.score != nil || d.about != nil {
                HStack(spacing: 10) {
                    if let s = d.score {
                        Text(s).font(Theme.body(13, .bold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.surface2))
                            .help(d.scoreFrom ?? "")
                    }
                    if let a = d.about { Text(a).font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1) }
                }
            }
            Text(d.map { $0.synopsis.isEmpty ? "No summary found yet." : $0.synopsis } ?? "Looking up what it's about…")
                .font(Theme.body(14)).foregroundStyle(d?.synopsis.isEmpty == false ? Theme.text : Theme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            StarPicker(key: entry.posterKey)
        }
    }
}

/// A film's page: poster, what it's about, how good it is, your stars, Play.
struct MovieSheet: View {
    let entry: LibraryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var log = WatchLog.shared
    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            PosterImage(entry: entry).frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(Theme.display(26)).lineLimit(2)
                    if let y = entry.year { Text(String(y)).font(Theme.body(14)).foregroundStyle(Theme.muted) }
                }
                AboutBlock(entry: entry)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    let resume = log.resumeAt(entry.url.lastPathComponent) != nil
                    Button(resume ? "Resume" : "Play") {
                        Task { await Streamer.shared.play(entry.url) }
                        dismiss()
                    }
                    .buttonStyle(RedButtonStyle())
                    Button("Close") { dismiss() }.buttonStyle(GhostButtonStyle())
                    if resume, let m = log.minutesLeft(entry.url.lastPathComponent) {
                        Text("\(m) min left").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 720, height: 360)
        .background(Theme.soil)
        .foregroundStyle(Theme.text)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        switch self { case .some(let w): return await f(w); case .none: return nil }
    }
}
