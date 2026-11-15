import Foundation
import Darwin

// Native lock and notification seams; the lease and policy below are extracted
// verbatim from production, with only the lease file redirected to this fixture.
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let testLeasePath = directory.appendingPathComponent("lease.json").path
var locked = false
var screenOff = false
var springboardLocked = false
var notificationLocked = false
var disagree = false
struct IcliLockStatus {
    var locked: Bool, screen_off: Bool, springboard_locked: Bool, notification_locked: Bool, sources_disagree: Bool
}
func icli_private_init() {}
func icli_lock_status() -> IcliLockStatus {
    IcliLockStatus(locked: locked, screen_off: screenOff, springboard_locked: springboardLocked,
                   notification_locked: notificationLocked, sources_disagree: disagree)
}
// PRODUCTION LOCK MESSAGE
func icli_notify_post(_ name: String, _ hasState: Bool, _ state: UInt64, _ delivered: inout Bool) -> Bool { true }
enum IcliError: Error { case locked; case commandFailed([String: Any]) }
// PRODUCTION LEASE
enum Envelope {
    static var warning: String?
// PRODUCTION POLICY
}
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { fatalError(message) }
}
func refused(_ body: () throws -> Void) throws {
    do { try body(); fatalError("exclusive command ran without holder token") }
    catch IcliError.commandFailed(let payload) { try require(payload["status"] as? Int == 75, "wrong lease exit") }
}
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
unsetenv("ICLI_LEASE")
try Envelope.applyLockPolicy(allowWhenLocked: false) // no lease: unchanged behavior
let now = Date().timeIntervalSince1970
let fixture: [String: Any] = ["token": "holder", "owner": "other-task", "acquired_at": now - 10,
                             "last_used_at": now - 5, "expires_at": now + 60, "idle_seconds": 600]
try Lease.store(fixture)
let before = try Data(contentsOf: URL(fileURLWithPath: Lease.path))
try refused { try Envelope.applyLockPolicy(allowWhenLocked: true) }
try Envelope.applyLockPolicy(allowWhenLocked: false, requiresLease: false)
try require(Data(contentsOf: URL(fileURLWithPath: Lease.path)) == before, "background command changed lease")
setenv("ICLI_LEASE", "wrong", 1)
try refused { try Envelope.applyLockPolicy(allowWhenLocked: true) }
Lease.bypass = true
try Envelope.applyLockPolicy(allowWhenLocked: false)
try require(Data(contentsOf: URL(fileURLWithPath: Lease.path)) == before, "bypass changed foreign lease")
Lease.bypass = false
try refused { try Envelope.applyLockPolicy(allowWhenLocked: true) }
try Envelope.applyLockPolicy(allowWhenLocked: true, requiresLease: false)
setenv("ICLI_LEASE", "holder", 1)
Lease.bypass = true
try Envelope.applyLockPolicy(allowWhenLocked: false)
try require(Data(contentsOf: URL(fileURLWithPath: Lease.path)) == before, "bypass renewed holder lease")
Lease.bypass = false
try Envelope.applyLockPolicy(allowWhenLocked: false, requiresLease: false)
try require(Data(contentsOf: URL(fileURLWithPath: Lease.path)) == before, "background command renewed holder lease")
try Envelope.applyLockPolicy(allowWhenLocked: false)
try require((Lease.current()?["last_used_at"] as? Double ?? 0) > now - 5, "holder interaction did not renew")
try require(Lease.current()?["token"] as? String == "holder", "holder token changed")
unsetenv("ICLI_LEASE")
for off in [false, true] {
    locked = !off; screenOff = off
    do { try Envelope.applyLockPolicy(allowWhenLocked: false, requiresLease: false); fatalError("background bypassed lock policy") }
    catch IcliError.locked {}
    try Envelope.applyLockPolicy(allowWhenLocked: true, requiresLease: false)
    Lease.bypass = true
    do { try Envelope.applyLockPolicy(allowWhenLocked: false); fatalError("lease bypass skipped device-lock policy") }
    catch IcliError.locked {}
    try Envelope.applyLockPolicy(allowWhenLocked: true)
    Lease.bypass = false
}
locked = false; screenOff = false
// Stale lockstate after a respring: SpringBoard unlocked, the notification
// locked. The command runs and says why.
springboardLocked = false; notificationLocked = true; disagree = true
try Envelope.applyLockPolicy(allowWhenLocked: false, requiresLease: false)
try require(Envelope.warning?.hasPrefix("lock sources disagree") == true, "disagreement not reported")
// A disagreement the keybag settles as locked still blocks.
locked = true
do { try Envelope.applyLockPolicy(allowWhenLocked: false, requiresLease: false); fatalError("keybag-locked disagreement ran") }
catch IcliError.locked {}
locked = false; notificationLocked = false; disagree = false
try Envelope.applyLockPolicy(allowWhenLocked: false, requiresLease: false)
try require(Envelope.warning == nil, "warning without a disagreement")
try Lease.store(fixture.merging(["expires_at": now - 1]) { _, new in new })
try Envelope.applyLockPolicy(allowWhenLocked: false)
print("PASS lease policy: default exclusion, background concurrency, bypass without renewal or ownership changes, owner renewal, screen-lock independence, lock-source disagreement, expiration")
