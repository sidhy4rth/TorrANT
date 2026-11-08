import SwiftUI
import AppKit

// MARK: - Link Grabber: finds download links in pasted text or on a web page

struct Grab: Identifiable, Equatable {
    enum Kind: String { case video = "VIDEO", archive = "ARCHIVE", torrent = "TORRENT", magnet = "MAGNET", file = "FILE" }
    let id = UUID()
    let url: String
    var name: String
    let kind: Kind
    var size: Int64?
    var picked = true
}

enum LinkGrabber {
    static let video: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "wmv", "flv"]
    static let archive: Set<String> = ["zip", "rar", "7z", "tar", "gz", "iso", "dmg", "pkg"]
    static let other: Set<String> = ["srt", "pdf", "epub", "mp3", "flac", "apk", "exe"]

    static func kind(of link: String) -> Grab.Kind? {
        if link.lowercased().hasPrefix("magnet:?") { return .magnet }
        guard let u = URL(string: link), let scheme = u.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme) else { return nil }
        let ext = u.pathExtension.lowercased()
        if ext == "torrent" { return .torrent }
        if video.contains(ext) { return .video }
        if archive.contains(ext) { return .archive }
        if other.contains(ext) { return .file }
        return nil
    }

    static func name(of link: String) -> String {
        if link.lowercased().hasPrefix("magnet:?"),
           let dn = URLComponents(string: link)?.queryItems?.first(where: { $0.name == "dn" })?.value { return dn }
        let last = URL(string: link)?.lastPathComponent ?? link
        return last.removingPercentEncoding ?? last
    }

    /// Every link in a block of text or HTML (href/src values and bare links), made absolute.
    static func links(in text: String, base: URL?) -> [String] {
        var out: [String] = []
        let patterns = [#"(?i)(?:href|src|data-src|data-url)\s*=\s*["']([^"'<>\s]+)["']"#,
                        #"(?i)(magnet:\?[^\s"'<>]+)"#,
                        #"(?i)\b((?:https?|ftp)://[^\s"'<>]+)"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                var s = String(text[r]).replacingOccurrences(of: "&amp;", with: "&")
                if !s.lowercased().hasPrefix("magnet:"), let base, let abs = URL(string: s, relativeTo: base)?.absoluteURL {
                    s = abs.absoluteString
                }
                out.append(s)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Plain links and magnets are taken as they are; anything else is treated as a page to search.
    static func grab(_ input: String) async -> (found: [Grab], pages: Int, failed: [String]) {
        var found: [Grab] = []
        var pages = 0
        var failed: [String] = []
        for line in input.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let k = kind(of: line) {
                found.append(Grab(url: line, name: name(of: line), kind: k))
            } else if let u = URL(string: line), ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
                // Ask first: only real web pages get read. A file behind an odd link
                // (download.php?id=…, .bin) is added as a download instead of being fetched.
                guard let head = await headInfo(u) else { failed.append(u.host ?? line); continue }
                if !head.isHTML {
                    found.append(Grab(url: line, name: head.name ?? name(of: line), kind: .file, size: head.size))
                    continue
                }
                guard let html = await fetchPage(u) else { failed.append(u.host ?? line); continue }
                pages += 1
                for l in links(in: html, base: u) {
                    if let k = kind(of: l) { found.append(Grab(url: l, name: name(of: l), kind: k)) }
                }
            }
        }
        var seen = Set<String>()
        found = found.filter { seen.insert($0.url).inserted }
        return (found, pages, failed)
    }

    static func headInfo(_ u: URL) async -> (isHTML: Bool, size: Int64?, name: String?)? {
        var req = URLRequest(url: u, timeoutInterval: 12)
        req.httpMethod = "HEAD"
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        var reply = try? await URLSession.shared.data(for: req)
        if (reply?.1 as? HTTPURLResponse).map({ $0.statusCode >= 400 }) ?? true {
            // Some servers refuse HEAD: peek at the first 2 KB instead of risking a whole file.
            req.httpMethod = "GET"
            req.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
            reply = try? await URLSession.shared.data(for: req)
        }
        guard let http = reply?.1 as? HTTPURLResponse, http.statusCode < 400 else { return nil }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let attachment = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().contains("attachment")
        let isHTML = !attachment && (type.isEmpty || type.contains("html") || type.contains("xml"))
        let (size, name) = await probe(Grab(url: u.absoluteString, name: "", kind: .file))
        return (isHTML, size, name)
    }

    static func fetchPage(_ u: URL) async -> String? {
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              let http = r as? HTTPURLResponse, http.statusCode < 400 else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    /// Size (and a better name) from the server, without downloading.
    static func probe(_ g: Grab) async -> (Int64?, String?) {
        guard g.kind != .magnet, let u = URL(string: g.url) else { return (nil, nil) }
        var req = URLRequest(url: u, timeoutInterval: 12)
        req.httpMethod = "HEAD"
        guard let (_, r) = try? await URLSession.shared.data(for: req), let http = r as? HTTPURLResponse,
              http.statusCode < 400 else { return (nil, nil) }
        let size = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        var name: String?
        if let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           let m = cd.range(of: #"filename\*?=(?:UTF-8'')?"?([^";]+)"?"#, options: .regularExpression) {
            name = String(cd[m]).replacingOccurrences(of: #"filename\*?=(?:UTF-8'')?"?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"", with: "").removingPercentEncoding
        }
        return (size, name)
    }
}

// MARK: - Night shift: a queue that runs inside a time window (1:00 to 7:00 by default)

@MainActor @Observable
final class NightShift {
    static let shared = NightShift()

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        let url: String
        let name: String
        let size: Int64?
        var added = Date()
        var sent = false
    }

    var items: [Item] = []
    var on: Bool = UserDefaults.standard.object(forKey: "nightOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(on, forKey: "nightOn") }
    }
    /// Minutes after midnight.
    var start: Int = UserDefaults.standard.object(forKey: "nightStart") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(start, forKey: "nightStart") }
    }
    var end: Int = UserDefaults.standard.object(forKey: "nightEnd") as? Int ?? 420 {
        didSet { UserDefaults.standard.set(end, forKey: "nightEnd") }
    }
    var running = false          // sent things during tonight's window
    var pausedForDay = false     // paused leftovers at the end of the window

    @ObservationIgnored private var looping = false
    @ObservationIgnored private var heldForWiFi = false

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT/night.json")
    }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([Item].self, from: d) { items = s }
        running = UserDefaults.standard.bool(forKey: "nightRunning")
        pausedForDay = UserDefaults.standard.bool(forKey: "nightPaused")
    }

    var waiting: [Item] { items.filter { !$0.sent } }
    var waitingBytes: Int64 { waiting.reduce(0) { $0 + ($1.size ?? 0) } }

    /// Holds the Mac awake from the moment a batch is queued until the night's work is handed over.
    var needsMacAwake: Bool { on && (!waiting.isEmpty || pausedForDay) }

    func inWindow(_ d: Date = Date()) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start <= end ? (m >= start && m < end) : (m >= start || m < end)
    }

    func nextStart(after d: Date = Date()) -> Date {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: d) ?? d
        return today > d ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    static func clock(_ minutes: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        let d = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return f.string(from: d)
    }

    func add(_ grabs: [Grab]) {
        let have = Set(items.filter { !$0.sent }.map(\.url))
        for g in grabs where !have.contains(g.url) {
            items.append(Item(url: g.url, name: g.name, size: g.size))
        }
        save()
        Colony.shared.say("Night shift: \(waiting.count) waiting for \(NightShift.clock(start))")
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    func clearSent() { items.removeAll { $0.sent }; save() }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: file, options: .atomic) }
        UserDefaults.standard.set(running, forKey: "nightRunning")
        UserDefaults.standard.set(pausedForDay, forKey: "nightPaused")
    }

    func begin() {
        guard !looping else { return }
        looping = true
        Task {
            while true {
                await tick()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func tick() async {
        guard on else { return }
        let colony = Colony.shared
        if inWindow() {
            guard colony.online else { return }
            // Never start a batch over a hotspot or Low Data Mode network.
            if NetWatch.shared.metered {
                if !waiting.isEmpty || pausedForDay, !heldForWiFi {
                    heldForWiFi = true
                    colony.say("Night shift waiting: you're on a hotspot or Low Data Mode")
                }
                return
            }
            heldForWiFi = false
            if pausedForDay {
                pausedForDay = false
                await colony.wakeAll()
                colony.say("Night shift: picking up where last night stopped")
            }
            let todo = waiting
            guard !todo.isEmpty else { save(); return }
            running = true
            for item in todo {
                if await colony.send(item.url), let i = items.firstIndex(where: { $0.id == item.id }) {
                    items[i].sent = true
                }
            }
            colony.say("Night shift: sent \(todo.count) download\(todo.count == 1 ? "" : "s")")
            PhoneLink.shared.notify("🌙 Night shift started: \(todo.count) download\(todo.count == 1 ? "" : "s") on the way")
            save()
        } else if running {
            // Window's over: pause anything still on the trail; it carries on tomorrow night.
            running = false
            let left = colony.trail.filter { $0.state == .active || $0.state == .waiting }.count
            if left > 0 {
                await colony.restAll()
                pausedForDay = true
                colony.say("Night shift over: \(left) paused, they'll finish tonight at \(NightShift.clock(start))")
                PhoneLink.shared.notify("☀️ Night shift over: \(left) unfinished, paused until tonight at \(NightShift.clock(start))")
            } else {
                colony.say("Night shift done ✓")
            }
            save()
        }
    }
}

// MARK: - The window

struct GrabberView: View {
    @State private var night = NightShift.shared
    @State private var up = Uploader.shared
    @State private var input = ""
    @State private var found: [Grab] = []
    @State private var busy = false
    @State private var note = ""

    var picked: [Grab] { found.filter(\.picked) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                main
                sidebar
            }
        }
        .background(SoilBackground().ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "link.badge.plus").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.red)
            Text("Link Grabber").font(Theme.display(24))
            Text("Paste links or a page. Grab now, or leave them for the night shift.")
                .font(Theme.body(14)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: up.straightToDrive ? "icloud.fill" : "laptopcomputer").font(.system(size: 12, weight: .semibold))
                Text(up.straightToDrive ? "Goes to Google Drive" : "Goes to this Mac").font(Theme.body(13, .semibold))
            }
            .foregroundStyle(up.straightToDrive ? Theme.safe : Theme.muted)
        }
        .padding(.leading, 22)
        .padding(.trailing, 18)
        .frame(height: 54)
        .background(Theme.deep)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.surface2).frame(height: 1) }
    }

    // MARK: Grab

    private var main: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $input)
                    .font(Theme.body(14))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                if input.isEmpty {
                    Text("Paste download links, magnets, or a web page address (one per line).\nPages are searched for videos, archives, torrents and magnets.")
                        .font(Theme.body(14)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.lineSoft, style: StrokeStyle(lineWidth: 2, dash: [7, 6])))

            HStack(spacing: 10) {
                Button(busy ? "Grabbing…" : "Grab links") { Task { await runGrab() } }
                    .buttonStyle(RedButtonStyle())
                    .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
                if busy { ProgressView().controlSize(.small) }
                Text(note).font(Theme.body(13)).foregroundStyle(Theme.muted)
                Spacer()
                if !found.isEmpty {
                    Button("All") { for i in found.indices { found[i].picked = true } }.buttonStyle(GhostButtonStyle())
                    Button("None") { for i in found.indices { found[i].picked = false } }.buttonStyle(GhostButtonStyle())
                }
            }

            if found.isEmpty {
                VStack(spacing: 12) {
                    AntSketch(pose: .walk).frame(width: 240)
                    Text("Nothing grabbed yet.").font(Theme.display(22))
                    Text("Paste a page full of links and the ants will sort out what's worth carrying.")
                        .font(Theme.body(14)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach($found) { $g in GrabRow(grab: $g) }
                    }
                }
                .scrollIndicators(.never)
                HStack(spacing: 10) {
                    let bytes = picked.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
                    Text("\(picked.count) picked" + (bytes > 0 ? " · \(Fmt.bytes(bytes))" : ""))
                        .font(Theme.body(14, .semibold))
                    Spacer()
                    Button("Download now") {
                        let p = picked
                        Task { for g in p { await Colony.shared.send(g.url) } }
                        found.removeAll(where: \.picked)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(picked.isEmpty)
                    Button("Add to night shift") {
                        night.add(picked)
                        found.removeAll(where: \.picked)
                    }
                    .buttonStyle(RedButtonStyle())
                    .disabled(picked.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func runGrab() async {
        busy = true; note = ""
        let r = await LinkGrabber.grab(input)
        let have = Set(found.map(\.url))
        found += r.found.filter { !have.contains($0.url) }
        var parts = ["\(r.found.count) link\(r.found.count == 1 ? "" : "s")"]
        if r.pages > 0 { parts.append("from \(r.pages) page\(r.pages == 1 ? "" : "s")") }
        if !r.failed.isEmpty { parts.append("couldn't open \(r.failed.joined(separator: ", "))") }
        note = parts.joined(separator: " ")
        busy = false
        if !r.found.isEmpty { input = "" }
        // Sizes and real names, a few at a time.
        await withTaskGroup(of: (UUID, Int64?, String?).self) { group in
            var n = 0
            for g in found where g.size == nil && g.kind != .magnet {
                if n >= 6, let (id, size, name) = await group.next() { apply(id, size, name); n -= 1 }
                group.addTask { let (s, nm) = await LinkGrabber.probe(g); return (g.id, s, nm) }
                n += 1
            }
            for await (id, size, name) in group { apply(id, size, name) }
        }
    }

    private func apply(_ id: UUID, _ size: Int64?, _ name: String?) {
        guard let i = found.firstIndex(where: { $0.id == id }) else { return }
        if let size { found[i].size = size }
        if let name, !name.isEmpty { found[i].name = name }
    }

    // MARK: Night shift

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "moon.stars.fill").foregroundStyle(Theme.chalk)
                Text("Night shift").font(Theme.display(22))
                Spacer()
                Toggle("", isOn: $night.on).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.safe)
            }
            HStack(spacing: 8) {
                timePicker("From", minutes: $night.start)
                timePicker("to", minutes: $night.end)
            }
            Text(status).font(Theme.body(13, .semibold)).foregroundStyle(night.on ? Theme.safe : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if night.items.isEmpty {
                Text("Nothing queued. Grab links and press Add to night shift.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface2))
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(night.items) { item in NightRow(item: item) }
                    }
                }
                .scrollIndicators(.never)
                if night.items.contains(where: \.sent) {
                    Button("Clear sent") { night.clearSent() }.buttonStyle(GhostButtonStyle())
                }
            }
            Spacer(minLength: 0)
            Text("Keep the Mac on, plugged in, lid open. TorrANT stops it sleeping while a batch is waiting; it can't wake a Mac that's already asleep.")
                .font(Theme.body(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.surface2).frame(width: 1) }
    }

    private var status: String {
        guard night.on else { return "Off. Queued links wait until you turn it back on." }
        if NetWatch.shared.metered { return "Waiting for Wi-Fi: on a hotspot or Low Data Mode" }
        let n = night.waiting.count
        let size = night.waitingBytes > 0 ? " · \(Fmt.bytes(night.waitingBytes))" : ""
        if night.inWindow() { return n > 0 ? "Working now · \(n) waiting\(size)" : "Working now · all sent" }
        if n == 0 { return night.pausedForDay ? "Leftovers continue at \(NightShift.clock(night.start))" : "Runs \(NightShift.clock(night.start)) to \(NightShift.clock(night.end))" }
        let secs = night.nextStart().timeIntervalSinceNow
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return "\(n) waiting\(size) · starts in \(h > 0 ? "\(h) h " : "")\(m) min"
    }

    private func timePicker(_ label: String, minutes: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.body(13)).foregroundStyle(Theme.muted)
            DatePicker("", selection: Binding(
                get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                }), displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.field)
        }
    }
}

private struct GrabRow: View {
    @Binding var grab: Grab
    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $grab.picked).toggleStyle(.checkbox).labelsHidden()
            Pill(text: grab.kind.rawValue,
                 fg: grab.kind == .torrent || grab.kind == .magnet ? Theme.swarmText : Theme.crumbText,
                 bg: grab.kind == .torrent || grab.kind == .magnet ? Theme.swarmTint : Theme.crumbTint)
                .frame(width: 86, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(grab.name).font(Theme.body(14, .semibold)).lineLimit(1).truncationMode(.middle)
                Text(URL(string: grab.url)?.host ?? (grab.kind == .magnet ? "magnet link" : ""))
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Text(grab.size.map { Fmt.bytes($0) } ?? (grab.kind == .magnet ? "" : "…"))
                .font(Theme.body(13)).foregroundStyle(Theme.muted).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .contentShape(Rectangle())
        .onTapGesture { grab.picked.toggle() }
        .opacity(grab.picked ? 1 : 0.55)
    }
}

private struct NightRow: View {
    let item: NightShift.Item
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.sent ? "checkmark.circle.fill" : "moon.zzz.fill")
                .foregroundStyle(item.sent ? Theme.safe : Theme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(Theme.body(13, .semibold)).lineLimit(1).truncationMode(.middle)
                Text(item.sent ? "Sent" : (item.size.map { Fmt.bytes($0) } ?? "Waiting"))
                    .font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if hover {
                Button { NightShift.shared.remove(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).help("Remove")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.surface2 : Theme.surface))
        .onHover { hover = $0 }
    }
}
