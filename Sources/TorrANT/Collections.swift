import Foundation

/// A film series, in order: Harry Potter (8), Transformers (7), Fast & Furious (10)…
struct FilmCollection: Codable, Equatable, Identifiable {
    struct Member: Codable, Equatable, Hashable {
        let qid: String
        let title: String
        let year: Int?
    }
    var id: String            // Wikidata id of the series
    var name: String
    var members: [Member]     // every film in the series, in order (owned or not)
    var fetched = Date()
}

/// Groups Library films into series, from Wikidata (free, no account): a film's page says
/// which series it's "part of" (P179), and the series gives the release order. Looked up once
/// per film and kept in App Support/TorrANT/posters/collections.json.
/// User's rules (15 Nov): a collection only appears once 2+ of its films are in the Library,
/// it shows only films you have (no suggestions, no "1 of 8"), shared universes like the
/// MCU are not collections, and collection films show only on the Collections tab.
@MainActor @Observable
final class Collections {
    static let shared = Collections()

    private struct Saved: Codable {
        var version = 2
        var series: [String: FilmCollection] = [:]
        var filmQID: [String: String] = [:]      // poster key → the film's Wikidata id
        var filmSeries: [String: String] = [:]   // poster key → series id ("" = not part of one)
    }

    private var saved = Saved()
    @ObservationIgnored private var missedAt: [String: Date] = [:]
    @ObservationIgnored private var fetching = false

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT/posters/collections.json")
    }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) { saved = s }
        // Version 1 picked the biggest series (the whole MCU): choose again with today's rules.
        if (try? JSONDecoder().decode(Version.self, from: (try? Data(contentsOf: file)) ?? Data()))?.version ?? 1 < 2 {
            saved.filmSeries = [:]; saved.version = 2
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: file, options: .atomic) }
    }

    private struct Version: Codable { var version: Int? }

    // MARK: Reading

    func seriesID(_ e: LibraryEntry) -> String? {
        guard !e.isShow, let s = saved.filmSeries[e.posterKey], !s.isEmpty, saved.series[s] != nil else { return nil }
        return s
    }

    /// Series with 2+ of their films in the Library.
    private func formed(_ entries: [LibraryEntry]) -> [String: Int] {
        var n: [String: Int] = [:]
        for e in entries { if let s = seriesID(e) { n[s, default: 0] += 1 } }
        return n.filter { $0.value >= 2 }
    }

    /// True when the film's series has 2+ films in the Library (then it lives on the Collections tab).
    func inCollection(_ e: LibraryEntry, among entries: [LibraryEntry]) -> Bool {
        guard let s = seriesID(e) else { return false }
        return formed(entries)[s] != nil
    }

    /// Collections you have 2+ films of, by name.
    func collections(in entries: [LibraryEntry]) -> [FilmCollection] {
        formed(entries).keys.compactMap { saved.series[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Your films of a series, in the series' order (ones Wikidata's list missed go in by year).
    func lineup(_ c: FilmCollection, entries: [LibraryEntry]) -> [LibraryEntry] {
        let place = Dictionary(c.members.enumerated().map { ($1.qid, $0) }, uniquingKeysWith: { a, _ in a })
        func key(_ e: LibraryEntry) -> (Int, Int) {
            if let q = saved.filmQID[e.posterKey], let i = place[q] { return (c.members[i].year ?? e.year ?? 0, i) }
            return (e.year ?? 0, Int.max)
        }
        return entries.filter { seriesID($0) == c.id }.sorted { key($0) < key($1) }
    }

    // MARK: Looking up

    /// Finds the series of films it hasn't checked yet. Misses try again at most hourly.
    func fetch(_ entries: [LibraryEntry]) async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        var changed = false
        for e in entries where !e.isShow && saved.filmSeries[e.posterKey] == nil {
            guard Date().timeIntervalSince(missedAt[e.posterKey] ?? .distantPast) > 3600 else { continue }
            var known = saved.filmQID[e.posterKey]
            if known == nil, let sum = await LibraryStore.wikiPage(e, needImage: false) { known = sum["wikibase_item"] as? String }
            guard let qid = known else {
                missedAt[e.posterKey] = Date()
                continue
            }
            saved.filmQID[e.posterKey] = qid
            var best: FilmCollection?
            for sid in await Collections.seriesOf(qid) {
                var c = saved.series[sid]
                if c == nil || Date().timeIntervalSince(c!.fetched) > 14 * 86400 {
                    c = await Collections.series(sid)
                    if let c { saved.series[sid] = c }
                }
                // A real series has 2+ films. Shared universes (the MCU, 39 films) aren't collections
                // (user, 15 Nov); of several series, the most specific (smallest) one wins.
                guard let c, c.members.count >= 2, c.members.count <= 30,
                      !c.name.localizedCaseInsensitiveContains("universe") else { continue }
                if best == nil || c.members.count < best!.members.count { best = c }
            }
            saved.filmSeries[e.posterKey] = best?.id ?? ""
            changed = true
        }
        if changed { save() }
    }

    /// The series (P179) a film is part of.
    nonisolated static func seriesOf(_ qid: String) async -> [String] {
        guard let d = await LibraryStore.json("https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=\(qid)&property=P179&format=json") as? [String: Any],
              let claims = (d["claims"] as? [String: Any])?["P179"] as? [[String: Any]] else { return [] }
        return claims.compactMap { (((($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] as? [String: Any])?["id"] as? String) }
    }

    /// Every film in a series with its place (P1545) and first release year, in order.
    nonisolated static func series(_ sid: String) async -> FilmCollection? {
        let sparql = """
        SELECT ?film ?filmLabel ?date ?ord ?seriesLabel WHERE {
          ?film p:P179 ?st . ?st ps:P179 wd:\(sid) .
          OPTIONAL { ?st pq:P1545 ?ord }
          ?film wdt:P31 ?t . VALUES ?t { wd:Q11424 wd:Q24869 wd:Q202866 wd:Q229390 }
          OPTIONAL { ?film wdt:P577 ?date }
          BIND(wd:\(sid) AS ?series)
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en,mul". }
        }
        """
        guard let q = sparql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))),
              let d = await LibraryStore.json("https://query.wikidata.org/sparql?format=json&query=\(q)") as? [String: Any],
              let rows = (d["results"] as? [String: Any])?["bindings"] as? [[String: Any]] else { return nil }
        func v(_ r: [String: Any], _ k: String) -> String? { (r[k] as? [String: Any])?["value"] as? String }

        var films: [String: (title: String, year: Int?, ord: Double?)] = [:]
        var name = sid
        for r in rows {
            guard let uri = v(r, "film"), let qid = uri.split(separator: "/").last.map(String.init) else { continue }
            name = v(r, "seriesLabel") ?? name
            let year = v(r, "date").flatMap { Int($0.prefix(4)) }
            let ord = v(r, "ord").flatMap(Double.init)
            let title = v(r, "filmLabel") ?? qid
            if let old = films[qid] {
                // A film has several release dates (festival, countries): keep the first.
                films[qid] = (old.title, [old.year, year].compactMap { $0 }.min(), old.ord ?? ord)
            } else {
                films[qid] = (title, year, ord)
            }
        }
        guard !films.isEmpty else { return nil }
        // Release order (how a series is usually watched); its number in the series breaks ties.
        let ordered = films.sorted { a, b in
            let ya = a.value.year ?? 9999, yb = b.value.year ?? 9999
            if ya != yb { return ya < yb }
            return (a.value.ord ?? 999) < (b.value.ord ?? 999)
        }
        let members = ordered.map { FilmCollection.Member(qid: $0.key, title: $0.value.title, year: $0.value.year) }
        // "Harry Potter film series" → "Harry Potter"
        let clean = name.replacingOccurrences(of: #"(?i)\s+(film series|film franchise|franchise|series)$"#, with: "", options: .regularExpression)
        return FilmCollection(id: sid, name: clean, members: members)
    }
}
