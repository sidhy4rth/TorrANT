import Foundation
import Network

/// Knows when the Mac is on a metered connection: a phone hotspot or cellular link macOS
/// flags as expensive, or any network with Low Data Mode turned on (System Settings →
/// Wi-Fi → Details). Many phone hotspots look like plain Wi-Fi, so Low Data Mode is the
/// reliable switch. On a metered connection TorrANT doesn't start night batches or preload.
@MainActor @Observable
final class NetWatch {
    static let shared = NetWatch()
    var metered = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    func start() {
        monitor.pathUpdateHandler = { path in
            let m = path.isExpensive || path.isConstrained
            Task { @MainActor in
                if m != NetWatch.shared.metered {
                    NetWatch.shared.metered = m
                    Colony.shared.say(m ? "On a hotspot or Low Data Mode: night shift and preloading wait for Wi-Fi"
                                        : "Back on regular Wi-Fi")
                    if !m { Streamer.shared.warmUp() }
                    Speed.shared.apply()   // hotspot limit on or off
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "torrant.net"))
    }
}
