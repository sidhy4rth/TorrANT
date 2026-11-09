import SwiftUI

/// Your Library on home Wi-Fi: a DLNA media server (rclone serve dlna) that smart TVs and VLC on
/// a phone find by themselves. It streams straight from Drive, read-only. Anyone on the same
/// network can browse it, so it's off until you turn it on.
@MainActor @Observable
final class HomeShare {
    static let shared = HomeShare()

    var on: Bool = UserDefaults.standard.bool(forKey: "homeShare") {
        didSet { UserDefaults.standard.set(on, forKey: "homeShare"); on ? start() : stop() }
    }
    var running = false

    @ObservationIgnored private var proc: Process?

    var shareName: String { "TorrANT on \(Host.current().localizedName ?? "this Mac")" }

    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TorrANT")
    }

    func start() {
        guard on, proc?.isRunning != true, Streamer.shared.state == .ready, let rclone = Streamer.shared.rclone,
              let dir = Colony.shared.driveDir,
              let rel = Streamer.pathInDrive(dir.appendingPathComponent("x"))?.split(separator: "/").dropLast().joined(separator: "/")
        else { return }
        // Its own cache folder: two rclone processes must not share one.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TorrANT/home-share")
        let log = support.appendingPathComponent("rclone-dlna.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclone)
        p.arguments = ["serve", "dlna", "drive:\(rel)", "--config", support.appendingPathComponent("rclone.conf").path,
                       "--name", shareName, "--addr", ":7879", "--read-only",
                       "--vfs-cache-mode", "full", "--cache-dir", cache.path, "--vfs-cache-max-size", "1G",
                       "--vfs-cache-max-age", "24h", "--vfs-read-ahead", "48M",
                       "--vfs-read-chunk-size", "8M", "--vfs-read-chunk-size-limit", "off",
                       "--drive-pacer-min-sleep", "10ms", "--drive-pacer-burst", "200", "--dir-cache-time", "1h"]
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { _ in Task { @MainActor in HomeShare.shared.running = false } }
        do {
            try p.run()
            proc = p; running = true
            Colony.shared.say("📺 Library shared on Wi-Fi as \"\(shareName)\" for TVs and VLC")
        } catch {
            Colony.shared.say("Couldn't share the Library on Wi-Fi: \(error.localizedDescription)")
        }
    }

    func stop() {
        proc?.terminate(); proc = nil; running = false
    }
}

struct HomeShareSettings: View {
    @State private var share = HomeShare.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Share the Library on home Wi-Fi (TVs and VLC on your phone)", isOn: $share.on)
                .toggleStyle(.checkbox).font(Theme.body(14))
            Text(share.running
                 ? "On as \"\(share.shareName)\". On a smart TV open its media / DLNA app; on a phone open VLC → Browse → Local network. Anyone on this Wi-Fi can see it."
                 : "Streams straight from Drive to any TV or phone on the same Wi-Fi. Anyone on that Wi-Fi can browse it, so only turn it on at home.")
                .font(Theme.body(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }
}
