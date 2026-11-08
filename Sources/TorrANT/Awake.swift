import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while ants are working (downloading or
/// queued). The screen can still turn off, and closing the lid still sleeps
/// a MacBook unless it's in clamshell mode. Seeding alone doesn't count.
@MainActor
final class Awake {
    static let shared = Awake()

    private var assertion: IOPMAssertionID = 0
    private(set) var holding = false

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "keepAwake")
            if !newValue { release() }
        }
    }

    /// Returns true when the state changed, so the caller can say so.
    @discardableResult
    func update(working: Bool) -> Bool {
        if working && enabled && !holding {
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "TorrANT is downloading" as CFString,
                &assertion)
            holding = ok == kIOReturnSuccess
            return holding
        }
        if (!working || !enabled) && holding {
            release()
            return true
        }
        return false
    }

    func release() {
        guard holding else { return }
        IOPMAssertionRelease(assertion)
        holding = false
    }
}
