import Foundation
import Darwin

// Native lock and notification seams; the lease and policy below are extracted
// verbatim from production, with only the lease file redirected to this fixture.
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let testLeasePath = directory.appendingPathComponent("lease.json").path
var locked = false
var screenOff = false
func icli_private_init() {}
func icli_lock_status() -> (locked: Bool, screen_off: Bool) { (locked, screenOff) }
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
try Envelope.applyLockPolicy(allowWhenLocked: true, requiresLease: false)
setenv("ICLI_LEASE", "holder", 1)
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
}
locked = false; screenOff = false
try Lease.store(fixture.merging(["expires_at": now - 1]) { _, new in new })
try Envelope.applyLockPolicy(allowWhenLocked: false)
print("PASS lease policy: default exclusion, background concurrency, no renewal with or without token, owner renewal, screen-lock independence, expiration")
