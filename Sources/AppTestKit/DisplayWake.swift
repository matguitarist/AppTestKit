import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while it is held. A sleeping display gives screencapture nothing: declaring user
/// activity wakes it, and an assertion keeps it on until this is released or the app quits.
public final class DisplayWake: Sendable {
    private let activity: IOPMAssertionID
    private let awake: IOPMAssertionID

    /// Wakes the display and keeps it on. `reason` shows in `pmset -g assertions`.
    public init(reason: String = "Snapshots") {
        var activity: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &activity)
        var awake: IOPMAssertionID = 0
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &awake)
        self.activity = activity
        self.awake = awake
    }

    deinit {
        if activity != 0 { IOPMAssertionRelease(activity) }
        if awake != 0 { IOPMAssertionRelease(awake) }
    }
}
