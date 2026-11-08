import Foundation
import Security
import SwiftUI

/// Your phone, through a private Telegram bot: share a link to the bot and it lands in the
/// night shift (or starts now). The bot answers only the one Telegram chat that paired with
/// the 6-digit code shown in Settings. The bot token is kept in the macOS Keychain.
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

    // MARK: Keychain

    private static let service = "com.sidhy4rth.torrant.telegram"

    private static func loadToken() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func saveToken(_ t: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let t, !t.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(t.utf8)
        SecItemAdd(add as CFDictionary, nil)
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
        while !Task.isCancelled {
            let r = await api(token, "getUpdates", ["timeout": 50, "offset": offset, "allowed_updates": ["message"]], wait: 60)
            guard let updates = r as? [[String: Any]] else {
                try? await Task.sleep(for: .seconds(5))   // offline or Telegram hiccup: try again shortly
                continue
            }
            for u in updates {
                if let id = (u["update_id"] as? NSNumber)?.int64Value { offset = max(offset, id + 1) }
                guard let m = u["message"] as? [String: Any],
                      let chat = (m["chat"] as? [String: Any])?["id"] as? NSNumber,
                      let text = (m["text"] as? String) ?? (m["caption"] as? String) else { continue }
                let from = ((m["from"] as? [String: Any])?["first_name"] as? String) ?? "you"
                await handle(text, chat: chat.int64Value, from: from, token: token)
            }
        }
    }

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
                await send(token, "🐜 Paired with TorrANT on your Mac.\n\nShare any link here and it goes to tonight's night shift. Add \"now\" to start it straight away. Send \"status\" any time.")
            } else {
                await api(token, "sendMessage", ["chat_id": chat, "text": "This bot belongs to someone's TorrANT. To pair, send /pair followed by the code shown in TorrANT's Settings."])
            }
            return
        }
        guard chat == chatID else { return }   // anyone else is ignored

        let lower = t.lowercased()
        if lower == "status" || lower == "/status" { await send(token, statusText()); return }
        if lower == "/start" || lower == "help" || lower == "/help" {
            await send(token, "Share or paste links (pages, files, magnets).\n• They wait for the night shift (\(NightShift.clock(NightShift.shared.start))–\(NightShift.clock(NightShift.shared.end))).\n• Add \"now\" to start straight away.\n• \"status\" shows what's waiting and downloading.")
            return
        }

        let now = lower.split(whereSeparator: { !$0.isLetter }).contains("now")
        let r = await LinkGrabber.grab(t)
        guard !r.found.isEmpty else {
            await send(token, r.failed.isEmpty ? "No download links in that. Send a link to a file, a page with downloads, or a magnet."
                                               : "Couldn't open \(r.failed.joined(separator: ", ")).")
            return
        }
        var grabs = Array(r.found.prefix(25))
        for i in grabs.indices where grabs[i].size == nil && grabs[i].kind != .magnet {
            let (size, name) = await LinkGrabber.probe(grabs[i])
            grabs[i].size = size
            if let name, !name.isEmpty { grabs[i].name = name }
        }
        let list = grabs.prefix(8).map { "• \($0.name)" + ($0.size.map { " (\(Fmt.bytes($0)))" } ?? "") }.joined(separator: "\n")
        let more = grabs.count > 8 ? "\n…and \(grabs.count - 8) more" : ""
        let capped = r.found.count > 25 ? "\n(First 25 of \(r.found.count) links on that page.)" : ""
        let dest = Uploader.shared.straightToDrive ? "Google Drive" : "the Mac"

        if now && !NetWatch.shared.metered {
            for g in grabs { await Colony.shared.send(g.url) }
            await send(token, "▶️ Starting now → \(dest):\n\(list)\(more)\(capped)")
        } else {
            NightShift.shared.add(grabs)
            let why = now ? "\nThe Mac is on a hotspot or Low Data Mode, so it waits for Wi-Fi." : ""
            await send(token, "🌙 Queued for tonight → \(dest):\n\(list)\(more)\(capped)\n\n\(nightLine())\(why)")
        }
    }

    // MARK: Telling the phone

    /// Short update to the paired phone (night shift started, something finished).
    func notify(_ text: String) {
        guard chatID != 0, let token = PhoneLink.loadToken() else { return }
        Task { await send(token, text) }
    }

    private func nightLine() -> String {
        let n = NightShift.shared
        guard n.on else { return "Night shift is off on the Mac, so nothing will start until it's on." }
        return "\(n.waiting.count) waiting · starts at \(NightShift.clock(n.start))"
    }

    private func statusText() -> String {
        let colony = Colony.shared
        let active = colony.trail.filter { $0.state == .active || $0.state == .waiting }
        var lines = ["🐜 TorrANT on your Mac", nightLine()]
        if !active.isEmpty {
            lines.append("Downloading now:")
            lines += active.prefix(6).map { "• \($0.name) — \(Int($0.progress * 100))%" }
        }
        if !Uploader.shared.jobs.isEmpty {
            lines.append("Going up to Drive:")
            lines += Uploader.shared.jobs.prefix(4).map { "• \($0.name)" }
        }
        if NetWatch.shared.metered { lines.append("On a hotspot / Low Data Mode: night shift waits for Wi-Fi.") }
        if active.isEmpty && Uploader.shared.jobs.isEmpty && NightShift.shared.waiting.isEmpty { lines.append("All quiet.") }
        return lines.joined(separator: "\n")
    }

    private func send(_ token: String, _ text: String) async {
        await api(token, "sendMessage", ["chat_id": chatID, "text": text, "disable_web_page_preview": true])
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
