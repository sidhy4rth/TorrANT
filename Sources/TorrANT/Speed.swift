import SwiftUI

/// "Step Aside": speed limits that follow the situation. The strictest one that applies wins:
/// your everyday limit, the hotspot / Low Data Mode limit, and quiet hours.
@MainActor @Observable
final class Speed {
    static let shared = Speed()

    /// Bytes per second; 0 = no limit.
    var downLimit: Int = UserDefaults.standard.integer(forKey: "speedDown") { didSet { save("speedDown", downLimit) } }
    var upLimit: Int = UserDefaults.standard.integer(forKey: "speedUp") { didSet { save("speedUp", upLimit) } }
    var meteredLimit: Int = UserDefaults.standard.object(forKey: "speedMetered") as? Int ?? 1_000_000 { didSet { save("speedMetered", meteredLimit) } }
    var quietOn: Bool = UserDefaults.standard.bool(forKey: "quietOn") { didSet { UserDefaults.standard.set(quietOn, forKey: "quietOn"); apply() } }
    var quietStart: Int = UserDefaults.standard.object(forKey: "quietStart") as? Int ?? 19 * 60 { didSet { save("quietStart", quietStart) } }
    var quietEnd: Int = UserDefaults.standard.object(forKey: "quietEnd") as? Int ?? 23 * 60 { didSet { save("quietEnd", quietEnd) } }
    var quietLimit: Int = UserDefaults.standard.object(forKey: "quietLimit") as? Int ?? 500_000 { didSet { save("quietLimit", quietLimit) } }

    /// What's in force right now, and why (shown in Settings and the chatter).
    var current: (down: Int, up: Int, why: String) = (0, 0, "")

    @ObservationIgnored private var started = false

    private func save(_ key: String, _ v: Int) { UserDefaults.standard.set(v, forKey: key); apply() }

    func begin() {
        guard !started else { return }
        started = true
        apply()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { Speed.shared.apply() }
        }
    }

    var inQuietHours: Bool {
        guard quietOn else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return quietStart <= quietEnd ? (m >= quietStart && m < quietEnd) : (m >= quietStart || m < quietEnd)
    }

    func apply() {
        var down = downLimit, why = downLimit > 0 ? "your limit" : ""
        func tighter(_ v: Int, _ reason: String) {
            guard v > 0, down == 0 || v < down else { return }
            down = v; why = reason
        }
        if NetWatch.shared.metered { tighter(meteredLimit, "hotspot / Low Data Mode") }
        if inQuietHours { tighter(quietLimit, "quiet hours") }
        let next = (down, upLimit, why)
        // Sent every time (a tiny local call), so a limit set before the engine was listening isn't lost.
        Colony.shared.setSpeedLimits(down: down, up: upLimit)
        guard next != current else { return }
        let first = current == (0, 0, "")
        current = next
        if !first || down > 0 {
            Colony.shared.say(down > 0 ? "Speed limit \(Speed.text(down)) (\(why))" : "No download speed limit")
        }
    }

    static func text(_ bps: Int) -> String {
        bps == 0 ? "No limit" : bps >= 1_000_000 ? "\(bps / 1_000_000) MB/s" : "\(bps / 1000) KB/s"
    }
}

/// Settings section.
struct SpeedSettings: View {
    @State private var speed = Speed.shared

    private func picker(_ title: String, _ value: Binding<Int>, _ options: [Int]) -> some View {
        HStack {
            Text(title).font(Theme.body(13)).frame(width: 210, alignment: .leading)
            Picker("", selection: value) {
                ForEach(options, id: \.self) { Text(Speed.text($0)).tag($0) }
            }
            .labelsHidden().frame(width: 140)
        }
    }

    private func clock(_ minutes: Binding<Int>) -> some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden().datePickerStyle(.field)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed").font(Theme.body(14, .semibold))
            picker("Download speed", $speed.downLimit, [0, 1_000_000, 2_000_000, 5_000_000, 10_000_000])
            picker("Upload speed", $speed.upLimit, [0, 256_000, 1_000_000])
            picker("On a hotspot / Low Data Mode", $speed.meteredLimit, [0, 256_000, 512_000, 1_000_000, 2_000_000])
            HStack(spacing: 8) {
                Toggle("Quiet hours", isOn: $speed.quietOn).toggleStyle(.checkbox).font(Theme.body(13))
                    .frame(width: 110, alignment: .leading)
                clock($speed.quietStart)
                Text("to").font(Theme.body(13)).foregroundStyle(Theme.muted)
                clock($speed.quietEnd)
                Picker("", selection: $speed.quietLimit) {
                    ForEach([256_000, 500_000, 1_000_000, 2_000_000], id: \.self) { Text(Speed.text($0)).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            Text(speed.current.down > 0 ? "Right now: \(Speed.text(speed.current.down)) (\(speed.current.why))" : "Right now: full speed")
                .font(Theme.body(12)).foregroundStyle(Theme.muted)
        }
    }
}
