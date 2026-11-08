import Foundation
import Security
import SwiftUI

/// Your phone, through a private Telegram bot: share a link to the bot and it lands in the
/// night shift (or starts now). The bot answers only the one Telegram chat that paired with
/// the 6-digit code shown in Settings. The bot token is kept in a private (owner-only) file.
@MainActor @Observable
final class PhoneLink {
    static let shared = PhoneLink()

    enum State: Equatable { case off, checking, waitingForPair(code: String), paired, problem(String) }

    var state: State = .off
    var botName = ""
    var pairedName: String = UserDefaults.standard.string(forKey: "phonePairedName") ?? ""

    @ObservationIgnored private var chatID: Int64 = Int64(UserDefaults.standard.integer(forKey: "phoneChatID"))
    @ObservationIgnored private var offset: Int64 = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var code = ""

    // MARK: Where the token lives
    //
    // A private file (owner-only, like rclone's Google sign-in), read once and kept in memory.
    // It used to be in the Keychain, but an ad-hoc-signed app looks new to macOS after every
    // build, so each read asked for your Mac password (8 Nov). Old Keychain copies move over once.

    private static let service = "com.sidhy4rth.torrant.telegram"
    nonisolated(unsafe) private static var cached: String?

    private static var tokenFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrANT/telegram-token")
    }

    private static func loadToken() -> String? {
        if let c = cached { return c }
        if let t = try? String(contentsOf: tokenFile, encoding: .utf8), !t.isEmpty {
            cached = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return cached
        }
        // One-time move from the Keychain (this read may ask for the password one last time).
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let t = String(data: d, encoding: .utf8) else { return nil }
        saveToken(t)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        return t
    }

    private static func saveToken(_ t: String?) {
        cached = t
        let fm = FileManager.default
        guard let t, !t.isEmpty else { try? fm.removeItem(at: tokenFile); return }
        try? fm.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: tokenFile.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
    }

    var hasToken: Bool { PhoneLink.loadToken() != nil }

    // MARK: Setup

    /// Called from Settings with the token BotFather gave you.
    func connect(token raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: #"^\d+:[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil else {
            state = .problem("That doesn't look like a bot token (it's like 123456789:ABC…)")
            return
        }
        PhoneLink.saveToken(token)
        chatID = 0; pairedName = ""
        UserDefaults.standard.removeObject(forKey: "phoneChatID")
        UserDefaults.standard.removeObject(forKey: "phonePairedName")
        start()
    }

    func disconnect() {
        loop?.cancel(); loop = nil
        PhoneLink.saveToken(nil)
        chatID = 0; pairedName = ""; botName = ""
        UserDefaults.standard.removeObject(forKey: "phoneChatID")
        UserDefaults.standard.removeObject(forKey: "phonePairedName")
        state = .off
    }

    /// At launch and after connecting: check the token, then listen.
    func start() {
        guard let token = PhoneLink.loadToken() else { state = .off; return }
        loop?.cancel()
        state = .checking
        loop = Task { [weak self] in
            guard let self else { return }
            guard let me = await self.api(token, "getMe", [:]) as? [String: Any],
                  let name = me["username"] as? String else {
                self.state = .problem("Telegram didn't accept that token")
                return
            }
            self.botName = name
            if self.chatID != 0 { self.state = .paired } else { self.newCode() }
            await self.listen(token)
        }
    }

    private func newCode() {
        code = String(format: "%06d", Int.random(in: 0...999_999))
        state = .waitingForPair(code: code)
    }

    // MARK: Listening (long polling: one request waits up to 50 s for messages)

    private func listen(_ token: String) async {
        await setUpMenu(token)
        while !Task.isCancelled {
            let r = await api(token, "getUpdates", ["timeout": 50, "offset": offset,
                                                    "allowed_updates": ["message", "callback_query"]], wait: 60)
            guard let updates = r as? [[String: Any]] else {
                try? await Task.sleep(for: .seconds(5))   // offline or Telegram hiccup: try again shortly
                continue
            }
            for u in updates {
                if let id = (u["update_id"] as? NSNumber)?.int64Value { offset = max(offset, id + 1) }
                if let q = u["callback_query"] as? [String: Any] { await tapped(q, token: token); continue }
                guard let m = u["message"] as? [String: Any],
                      let chat = (m["chat"] as? [String: Any])?["id"] as? NSNumber,
                      let text = (m["text"] as? String) ?? (m["caption"] as? String) else { continue }
                let from = ((m["from"] as? [String: Any])?["first_name"] as? String) ?? "you"
                await handle(text, chat: chat.int64Value, from: from, token: token)
            }
        }
    }

    // MARK: Buttons and menus

    /// The "/" command list Telegram shows in the chat.
    private func setUpMenu(_ token: String) async {
        await api(token, "setMyCommands", ["commands": [
            ["command": "status", "description": "Live view of what's downloading"],
            ["command": "queue", "description": "Tonight's night shift"],
            ["command": "pause", "description": "Let all the ants rest"],
            ["command": "resume", "description": "Wake all the ants"],
            ["command": "help", "description": "How to use this bot"]]])
    }

    /// Big buttons that sit under the chat box.
    private var keyboard: [String: Any] {
        ["keyboard": [[["text": "📊 Status"], ["text": "🌙 Queue"]], [["text": "⏸ Pause all"], ["text": "▶️ Resume all"]]],
         "resize_keyboard": true, "is_persistent": true]
    }

    nonisolated(unsafe) static let noButtons: [String: Any] = ["inline_keyboard": [[[String: Any]]]()]

    private func inline(_ rows: [[(String, String)]]) -> [String: Any] {
        ["inline_keyboard": rows.map { $0.map { ["text": $0.0, "callback_data": $0.1] } }]
    }

    /// Buttons under a "queued" reply point at the items it added (callback data is capped at 64 bytes).
    @ObservationIgnored private var batches: [String: [UUID]] = [:]
    @ObservationIgnored private var dupeOffers: [String: (grabs: [Grab], now: Bool)] = [:]

    // MARK: Messages

    private func handle(_ text: String, chat: Int64, from: String, token: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pairing: only the chat that sends the code shown on the Mac gets in.
        if chatID == 0 {
            if t.lowercased().hasPrefix("/pair"), t.contains(code), !code.isEmpty {
                chatID = chat; pairedName = from
                UserDefaults.standard.set(Int(chat), forKey: "phoneChatID")
                UserDefaults.standard.set(from, forKey: "phonePairedName")
                state = .paired
                Colony.shared.say("Phone paired: \(from) on Telegram")
                await api(token, "sendMessage", ["chat_id": chatID, "reply_markup": keyboard, "text":
                    "🐜 Paired with TorrANT on your Mac!\n\nShare any link here and the ants carry it on tonight's night shift. Add \"now\" to start straight away.\n\nThe buttons below show what's happening, live."])
            } else {
                await api(token, "sendMessage", ["chat_id": chat, "text": "This bot belongs to someone's TorrANT. To pair, send /pair followed by the code shown in TorrANT's Settings."])
            }
            return
        }
        guard chat == chatID else { return }   // anyone else is ignored

        // "📊 Status", "/status" and "status" all mean the same thing.
        let word = String(t.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
        switch word {
        case "status": await startLive(token); return
        case "queue": await sendQueue(token); return
        case "pause", "pause all":
            await Colony.shared.restAll()
            await reply(token, "⏸ All the ants are resting. Tap ▶️ Resume all when you're ready."); return
        case "resume", "resume all":
            if NetWatch.shared.metered { await reply(token, "📵 The Mac is on a hotspot or Low Data Mode, so nothing resumes until it's on Wi-Fi."); return }
            await Colony.shared.wakeAll()
            await startLive(token); return
        case "start", "help":
            await reply(token, """
            🐜 How it works
            • Share or paste links: files, pages full of downloads, or magnets.
            • They wait for the night shift (\(NightShift.clock(NightShift.shared.start))–\(NightShift.clock(NightShift.shared.end))). Add "now" to start straight away.
            • 📊 Status: a live view that updates itself.
            • 🌙 Queue: tonight's list, with buttons to start or remove things.
            • When a movie reaches your Library you get its poster here.
            """); return
        default: break
        }

        let now = t.lowercased().split(whereSeparator: { !$0.isLetter }).contains("now")
        let r = await LinkGrabber.grab(t)
        guard !r.found.isEmpty else {
            await reply(token, r.failed.isEmpty ? "🤔 No download links in that. Send a link to a file, a page with downloads, or a magnet."
                                                : "🚧 Couldn't open \(r.failed.joined(separator: ", ")).")
            return
        }
        var grabs = Array(r.found.prefix(25))
        for i in grabs.indices where grabs[i].size == nil && grabs[i].kind != .magnet {
            let (size, name) = await LinkGrabber.probe(grabs[i])
            grabs[i].size = size
            if let name, !name.isEmpty { grabs[i].name = name }
        }
        // Hold back what you already have; offer it with a button instead of queueing it.
        var dupes: [Grab] = []
        for g in grabs {
            if let have = await LibraryStore.shared.alreadyHave(g.name) { var d = g; d.have = have; dupes.append(d) }
        }
        let dupeURLs = Set(dupes.map(\.url))
        grabs.removeAll { dupeURLs.contains($0.url) }
        if !dupes.isEmpty {
            let key = String(UUID().uuidString.prefix(8))
            dupeOffers[key] = (dupes, now)
            let lines = dupes.prefix(8).map { "• \($0.have ?? $0.name)" }.joined(separator: "\n")
            await api(token, "sendMessage", [
                "chat_id": chatID, "disable_web_page_preview": true,
                "text": "📚 You already have \(dupes.count == 1 ? "this" : "these \(dupes.count)"):\n\(lines)\n\nSkipped so you don't spend data twice.",
                "reply_markup": inline([[("⬇️ Get \(dupes.count == 1 ? "it" : "them") anyway", "ga:\(key)")]])])
            if grabs.isEmpty { return }
        }
        let total = grabs.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let list = grabs.prefix(8).map { "• \($0.name)" + ($0.size.map { " · \(Fmt.bytes($0))" } ?? "") }.joined(separator: "\n")
        let more = grabs.count > 8 ? "\n…and \(grabs.count - 8) more" : ""
        let capped = r.found.count > 25 ? "\n(First 25 of \(r.found.count) links on that page.)" : ""
        let dest = Uploader.shared.straightToDrive ? "☁️ Google Drive" : "💻 the Mac"
        let size = total > 0 ? " · \(Fmt.bytes(total))" : ""

        if now && !NetWatch.shared.metered {
            for g in grabs { await Colony.shared.send(g.url) }
            await reply(token, "▶️ The ants are on it → \(dest)\(size)\n\(list)\(more)\(capped)")
            await startLive(token)
        } else {
            let added = NightShift.shared.add(grabs)
            let key = String(UUID().uuidString.prefix(8))
            batches[key] = added.map(\.id)
            let why = now ? "\n📵 The Mac is on a hotspot or Low Data Mode, so it waits for Wi-Fi." : ""
            await api(token, "sendMessage", [
                "chat_id": chatID, "disable_web_page_preview": true,
                "text": "🌙 Queued for tonight → \(dest)\(size)\n\(list)\(more)\(capped)\n\n\(nightLine())\(why)",
                "reply_markup": inline([[(added.count > 1 ? "▶️ Start all now" : "▶️ Start now", "nb:\(key)"),
                                         (added.count > 1 ? "❌ Remove all" : "❌ Remove", "rb:\(key)")]])])
        }
    }

    /// A button under one of the bot's messages was tapped.
    private func tapped(_ q: [String: Any], token: String) async {
        let qid = q["id"] as? String ?? ""
        let msg = q["message"] as? [String: Any]
        let chat = ((msg?["chat"] as? [String: Any])?["id"] as? NSNumber)?.int64Value ?? 0
        let mid = (msg?["message_id"] as? NSNumber)?.intValue ?? 0
        let oldText = msg?["text"] as? String ?? ""
        guard chat == chatID, chatID != 0, let data = q["data"] as? String else {
            await api(token, "answerCallbackQuery", ["callback_query_id": qid]); return
        }
        let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        func answer(_ s: String) async { await api(token, "answerCallbackQuery", ["callback_query_id": qid, "text": s]) }
        func edit(_ text: String, _ markup: [String: Any] = PhoneLink.noButtons) async {
            await api(token, "editMessageText", ["chat_id": chatID, "message_id": mid, "text": text,
                                                 "reply_markup": markup, "disable_web_page_preview": true])
        }

        switch parts[0] {
        case "nb", "go":
            if NetWatch.shared.metered { await answer("📵 On a hotspot: waits for Wi-Fi"); return }
            let ids = parts[0] == "nb" ? (batches[arg] ?? []) : (UUID(uuidString: arg).map { [$0] } ?? [])
            let n = await NightShift.shared.startNow(ids)
            await answer(n > 0 ? "▶️ Started \(n)" : "Already started or removed")
            if parts[0] == "nb" { await edit(oldText + "\n\n▶️ Started now") } else { await edit(queueText(), queueButtons()) }
            if n > 0 { await startLive(token) }
        case "rb", "rm":
            let ids = parts[0] == "rb" ? (batches[arg] ?? []) : (UUID(uuidString: arg).map { [$0] } ?? [])
            ids.forEach { NightShift.shared.remove($0) }
            await answer("❌ Removed")
            if parts[0] == "rb" { await edit(oldText + "\n\n❌ Removed from tonight") } else { await edit(queueText(), queueButtons()) }
        case "ga":
            guard let offer = dupeOffers.removeValue(forKey: arg) else { await answer("Already handled"); return }
            if offer.now && !NetWatch.shared.metered {
                for g in offer.grabs { await Colony.shared.send(g.url) }
                await answer("▶️ Downloading anyway")
                await edit(oldText + "\n\n▶️ Downloading anyway")
                await startLive(token)
            } else {
                NightShift.shared.add(offer.grabs)
                await answer("🌙 Added to tonight")
                await edit(oldText + "\n\n🌙 Added to tonight anyway")
            }
        case "refresh":
            await answer("Updated")
            await edit(dashboard(), busy ? liveButtons : PhoneLink.noButtons)
        case "pauseall":
            await Colony.shared.restAll(); await answer("⏸ Paused")
            await edit(dashboard(), liveButtons)
        case "resumeall":
            if NetWatch.shared.metered { await answer("📵 On a hotspot: waits for Wi-Fi"); return }
            await Colony.shared.wakeAll(); await answer("▶️ Resumed")
            await startLive(token)
        default:
            await answer("")
        }
    }

    // MARK: Queue

    private func queueText() -> String {
        let n = NightShift.shared
        let w = n.waiting
        guard !w.isEmpty else { return "🌙 Nothing queued for tonight.\nShare a link here to add one." }
        let list = w.prefix(10).enumerated().map { i, it in
            "\(i + 1). \(it.name)" + (it.size.map { " · \(Fmt.bytes($0))" } ?? "")
        }.joined(separator: "\n")
        let more = w.count > 10 ? "\n…and \(w.count - 10) more" : ""
        return "🌙 Tonight's night shift · \(w.count) waiting" + (n.waitingBytes > 0 ? " · \(Fmt.bytes(n.waitingBytes))" : "")
            + "\nStarts \(NightShift.clock(n.start)), stops \(NightShift.clock(n.end))\n\n\(list)\(more)"
    }

    private func queueButtons() -> [String: Any] {
        let rows = NightShift.shared.waiting.prefix(10).enumerated().map { i, it in
            [("▶️ \(i + 1) now", "go:\(it.id.uuidString)"), ("❌ \(i + 1)", "rm:\(it.id.uuidString)")]
        }
        return inline(Array(rows))
    }

    private func sendQueue(_ token: String) async {
        await api(token, "sendMessage", ["chat_id": chatID, "text": queueText(), "reply_markup": queueButtons(),
                                         "disable_web_page_preview": true])
    }

    // MARK: Live view: one message that keeps updating itself

    @ObservationIgnored private var liveTask: Task<Void, Never>?

    private var busy: Bool {
        Colony.shared.trail.contains { $0.state == .active || $0.state == .waiting } || !Uploader.shared.jobs.isEmpty
            || !Colony.shared.unpacking.isEmpty
    }

    private var liveButtons: [String: Any] {
        inline([[("🔄 Refresh", "refresh"), ("⏸ Pause all", "pauseall"), ("▶️ Resume", "resumeall")]])
    }

    private static func bar(_ p: Double) -> String {
        let n = max(0, min(10, Int((p * 10).rounded())))
        return String(repeating: "▰", count: n) + String(repeating: "▱", count: 10 - n)
    }

    private static func short(_ s: String) -> String { s.count > 34 ? String(s.prefix(32)) + "…" : s }

    private func dashboard() -> String {
        let colony = Colony.shared
        var lines = ["🐜 TorrANT · live"]
        let trail = colony.trail.filter { $0.state == .active || $0.state == .waiting || $0.state == .paused }
        for c in trail.prefix(6) {
            let icon = c.state == .paused ? "⏸" : (c.kind == .swarm ? "🐜" : "⬇️")
            var info = "\(Int(c.progress * 100))%"
            if c.state == .active, c.down > 0 {
                info += " · \(Fmt.speed(c.down))"
                if c.total > c.done { info += " · \(Fmt.eta(Double(c.total - c.done) / Double(c.down))) left" }
            } else if c.state == .paused { info += " · resting" } else { info += " · waiting" }
            lines.append("\n\(icon) \(PhoneLink.short(c.name))\n\(PhoneLink.bar(c.progress)) \(info)")
        }
        for name in colony.unpacking.values.prefix(3) { lines.append("\n📦 Unpacking \(PhoneLink.short(name))") }
        for j in Uploader.shared.jobs.prefix(4) {
            let p = j.size > 0 ? min(1, j.done / j.size) : 0
            lines.append("\n☁️ \(PhoneLink.short(j.name))\n\(PhoneLink.bar(p)) \(Int(p * 100))% · \(Fmt.speed(Int(j.speed)))")
        }
        if lines.count == 1 { lines.append("\nAll quiet. The ants are resting 😴") }
        lines.append("\n🌙 " + nightLine())
        if NetWatch.shared.metered { lines.append("📵 Hotspot / Low Data Mode: night shift waits for Wi-Fi") }
        lines.append("Updated \(NightShift.clock(Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())))")
        return lines.joined(separator: "\n")
    }

    /// Sends the live view, then edits it every 6 s until everything's done (at most 2 hours).
    private func startLive(_ token: String) async {
        liveTask?.cancel()
        guard let r = await api(token, "sendMessage", ["chat_id": chatID, "text": dashboard(),
                                                       "reply_markup": busy ? liveButtons : PhoneLink.noButtons]) as? [String: Any],
              let mid = (r["message_id"] as? NSNumber)?.intValue, busy else { return }
        liveTask = Task { [weak self] in
            var last = ""
            for _ in 0..<1200 {
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled else { return }
                let still = self.busy
                let text = self.dashboard() + (still ? "" : "\n\n✅ All done!")
                if text != last {
                    last = text
                    await self.api(token, "editMessageText", ["chat_id": self.chatID, "message_id": mid, "text": text,
                                                              "reply_markup": still ? self.liveButtons : PhoneLink.noButtons])
                }
                if !still { return }
            }
        }
    }

    // MARK: Telling the phone

    /// Short update to the paired phone (night shift started, something finished).
    func notify(_ text: String, live: Bool = false) {
        guard chatID != 0, let token = PhoneLink.loadToken() else { return }
        Task {
            await reply(token, text)
            if live { await startLive(token) }
        }
    }

    /// Something reached Drive: send its poster if the Library knows it (Drive takes a moment to list new things).
    func announceReady(_ name: String) {
        guard chatID != 0, let token = PhoneLink.loadToken() else { return }
        Task {
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(20)) }
                await LibraryStore.shared.refresh()
                let store = LibraryStore.shared
                if let e = store.entries.first(where: { $0.url.lastPathComponent == name }) {
                    let what = e.isShow ? "Season \(e.season ?? 1) · \(e.episodes.count) episodes" : (e.year.map(String.init) ?? "")
                    let caption = "🍿 \(e.title)\(what.isEmpty ? "" : " · \(what)")\nIn your Library, ready to stream."
                    if let poster = store.posters[e.posterKey], let img = try? Data(contentsOf: poster) {
                        await sendPhoto(token, img, caption: caption)
                    } else {
                        await reply(token, caption)
                    }
                    return
                }
            }
            await reply(token, "☁️ \(name) is in Google Drive")
        }
    }

    private func nightLine() -> String {
        let n = NightShift.shared
        guard n.on else { return "Night shift is off on the Mac, so nothing starts until it's on." }
        return n.waiting.isEmpty ? "Night shift: nothing waiting" : "\(n.waiting.count) waiting · starts at \(NightShift.clock(n.start))"
    }

    private func reply(_ token: String, _ text: String) async {
        await api(token, "sendMessage", ["chat_id": chatID, "text": text, "disable_web_page_preview": true,
                                         "reply_markup": keyboard])
    }

    private func sendPhoto(_ token: String, _ img: Data, caption: String) async {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendPhoto") else { return }
        let b = "torrant-\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append(Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".utf8))
        }
        field("chat_id", String(chatID))
        field("caption", caption)
        body.append(Data("--\(b)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"poster.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(img)
        body.append(Data("\r\n--\(b)--\r\n".utf8))
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }

    @discardableResult
    private func api(_ token: String, _ method: String, _ body: [String: Any], wait: TimeInterval = 20) async -> Any? {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: wait)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (j["ok"] as? Bool) == true else { return nil }
        return j["result"]
    }
}

/// Settings section: paste the BotFather token, then pair with a code.
struct PhoneSettings: View {
    @State private var phone = PhoneLink.shared
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phone (Telegram)").font(Theme.body(14, .semibold))
            switch phone.state {
            case .off, .problem:
                Text("Send links from your phone to tonight's night shift. In Telegram, message @BotFather, send /newbot, and paste the token it gives you here.")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Bot token", text: $token).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    Button("Connect") { phone.connect(token: token); token = "" }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if case .problem(let why) = phone.state {
                    Text(why).font(Theme.body(12)).foregroundStyle(Theme.red)
                }
            case .checking:
                Text("Checking the token with Telegram…").font(Theme.body(12)).foregroundStyle(Theme.muted)
            case .waitingForPair(let code):
                Text("Now open @\(phone.botName) in Telegram on your phone and send:")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted)
                Text("/pair \(code)").font(.system(size: 18, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
                Button("Use a different bot") { phone.disconnect() }
            case .paired:
                HStack(spacing: 8) {
                    Circle().fill(Theme.safe).frame(width: 8, height: 8)
                    Text("Paired with \(phone.pairedName) through @\(phone.botName)").font(Theme.body(13))
                }
                Text("Share links to the bot: they wait for the night shift. Add \"now\" to start straight away, or send \"status\".")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Unpair phone") { phone.disconnect() }
            }
        }
    }
}
