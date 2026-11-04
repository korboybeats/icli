import Foundation
import IcliPrivate

/// Paces a wait by the frames the display shows: after a check it sleeps until
/// the screen changes, so a still screen costs no checks. A change after a quiet
/// spell is checked at once; while frames keep coming, checks stay `interval`
/// apart. Where frame notifications are unavailable it sleeps `interval`.
struct FrameGate {
    let active: Bool
    private var seen: UInt64 = 0

    init() { active = icli_frames_begin() }

    var trigger: String { active ? "frames" : "poll" }

    func close() { if active { icli_frames_end() } }

    /// Call just before a check, so a frame drawn during the check wakes the next wait.
    mutating func mark() { if active { seen = icli_frames_count() } }

    /// Sleeps until a frame after the last mark, at most `limit` seconds, then
    /// for what is left of `interval` since `checked`. False when no frame came.
    func wait(limit: TimeInterval, interval: TimeInterval, since checked: TimeInterval) -> Bool {
        let limit = max(0, limit)
        guard active else {
            Thread.sleep(forTimeInterval: min(interval, limit))
            return true
        }
        let start = ProcessInfo.processInfo.systemUptime
        guard icli_frames_wait(seen, limit) != seen else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let gap = min(interval - (now - checked), limit - (now - start))
        if gap > 0 { Thread.sleep(forTimeInterval: gap) }
        return true
    }
}
