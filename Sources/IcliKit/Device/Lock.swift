import Foundation
import IcliPrivate

/// Request the existing power-button action once, then verify lock and blanking.
/// An already locked/blanked device is left alone; never toggle an off screen.
public func lockDevice() throws -> [String: Any] {
    #if os(tvOS)
    throw IcliError.unavailable("tvOS has no device lock screen")
    #else
    icli_private_init()
    let before = icli_lock_status()
    if before.locked && before.screen_off {
        return ["status": 0, "locked": true, "screen_off": true,
                "requested": false, "already_locked": true]
    }
    guard !before.screen_off else {
        throw IcliError.failed("screen is off but lock state is unconfirmed; no power press was sent")
    }
    // icli_lock_status reads these two names' state, which SpringBoard sets
    // before it posts them, so each post wakes the check instead of a 50 ms poll.
    let names = ["com.apple.springboard.lockstate", "com.apple.springboard.hasBlankedScreen"]
    let watch = names.withCStringArray { icli_watch_notify($0, Int32(names.count)) }
    defer { if let watch { icli_watch_end(watch) } }
    guard icli_hid_button("power") else { throw IcliError.failed("power-button dispatch failed; lock is unconfirmed") }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while true {
        let seen = watch.map { icli_watch_count($0) } ?? 0
        let state = icli_lock_status()
        if state.locked && state.screen_off {
            return ["status": 0, "locked": true, "screen_off": true,
                    "requested": true, "already_locked": false]
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 {
            return ["status": 3, "locked": state.locked, "screen_off": state.screen_off,
                    "requested": true, "already_locked": false,
                    "message": "power press sent, but locked/screen-off state was not confirmed; no retry was sent"]
        }
        if let watch { _ = icli_watch_wait(watch, seen, remaining) } else { Thread.sleep(forTimeInterval: min(0.05, remaining)) }
    }
    #endif
}
