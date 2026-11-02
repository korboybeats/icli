import Darwin
import Foundation

// Production policy plus a real ledger, with fake platform boundaries.
// These tests never contact a phone or spend a device passcode attempt.
enum IcliError: Error { case failed(String), unavailable(String) }
struct LockStatus { var locked: Bool; var screen_off: Bool }
var os: [String: Any] = [:]
var screen = LockStatus(locked: true, screen_off: true)
var fullCalls = 0, keybagCalls = 0, preflights = 0
var reject = false, unavailable = false, falseSuccess = false, uncounted = false
var signalBegins = 0, signalEnds = 0
var signalBeginAvailable = true, signalEndAvailable = true
var signalEndObservation: (() -> Void)?
func icli_full_unlock_signals_begin() -> Bool { signalBegins += 1; return signalBeginAvailable }
func icli_full_unlock_signals_end() -> Bool { signalEnds += 1; signalEndObservation?(); return signalEndAvailable }
func json(_ object: [String: Any]) -> UnsafeMutablePointer<CChar>? {
    strdup(String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
}
func icli_keybag_info_json() -> UnsafeMutablePointer<CChar>? { json(os) }
func takeCString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }; defer { free(p) }; return String(cString: p)
}
func decodeBridgeJSON(_ s: String?, _ what: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(s!.utf8)) as! [String: Any]
}
func icli_lock_status() -> LockStatus { screen }
func icli_full_unlock_json(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ checkOnly: Bool) -> UnsafeMutablePointer<CChar>? {
    if checkOnly { preflights += 1; return json(["ready": !unavailable, "attempted": false, "confirmed": false]) }
    fullCalls += 1
    if unavailable { return json(["ready": false, "attempted": false, "confirmed": false, "detail": "unavailable"]) }
    if reject { os["failed_attempts"] = (os["failed_attempts"] as! Int) + 1 }
    if !reject && !uncounted {
        os["lock_state"] = 0
        if !falseSuccess { screen = LockStatus(locked: false, screen_off: false) }
    }
    return json(["ready": true, "attempted": true, "confirmed": !reject && !uncounted, "detail": "fixture result"])
}
func icli_keybag_unlock(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ available: inout Bool) -> Int32 {
    keybagCalls += 1; available = true; os["lock_state"] = 0; return 0
}
enum Failure: Error { case check(String) }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.check(message) }
}
let work = CommandLine.arguments[1]
var sequence = 0
func fresh() -> PasscodeLedger {
    os = ["lock_state": 1, "failed_attempts": 0, "backoff_seconds": 0]
    screen = LockStatus(locked: true, screen_off: true)
    fullCalls = 0; keybagCalls = 0; preflights = 0
    reject = false; unavailable = false; falseSuccess = false; uncounted = false
    signalBegins = 0; signalEnds = 0; signalBeginAvailable = true; signalEndAvailable = true
    signalEndObservation = nil
    sequence += 1
    return PasscodeLedger(path: "\(work)/\(sequence)/ledger.json")
}
func run(_ ledger: PasscodeLedger, checkOnly: Bool = false, dismiss: Bool = true) throws -> [String: Any] {
    var secret = Array("fixture-passcode".utf8)
    defer { assert(secret.isEmpty, "owned passcode bytes must be wiped on every return") }
    return try unlockDevice(passcode: &secret, checkOnly: checkOnly, ledger: ledger, dismissLockScreen: dismiss)
}
let tests: [(String, () throws -> Void)] = [
    ("one full unlock, no separate keybag attempt", {
        let l = fresh(); let r = try run(l)
        try check(r["ui_unlocked"] as? Bool == true && r["status"] as? Int == 0, "confirmed success")
        try check(fullCalls == 1 && keybagCalls == 0, "single attempt")
    }),
    ("signal scope remains active until the rejected attempt is persisted", {
        let l = fresh(); reject = true; var persisted = false
        signalEndObservation = {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: l.path)),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rejected = object["rejected"] as? [[String: Any]] {
                persisted = rejected.count == 1
            }
        }
        let r = try run(l)
        try check(r["status"] as? Int == 3 && signalBegins == 1 && signalEnds == 1 && persisted, "ledger must be committed before deferred signals resume")
    }),
    ("failure to protect signals prevents any attempt", {
        let l = fresh(); signalBeginAvailable = false; let r = try run(l)
        try check(r["status"] as? Int == 6 && fullCalls == 0 && keybagCalls == 0 && signalEnds == 0, "fail before target execution")
    }),
    ("signal restoration failure cannot be reported as clean success", {
        let l = fresh(); signalEndAvailable = false; let r = try run(l)
        try check(r["status"] as? Int == 6 && signalEnds == 1, "report signal cleanup failure")
    }),
    ("unlocked keybag with visible lock screen still invokes full unlock", {
        let l = fresh(); os["lock_state"] = 0; _ = try run(l)
        try check(fullCalls == 1, "do not return before UI unlock")
    }),
    ("already awake and unlocked makes no request", {
        let l = fresh(); os["lock_state"] = 0; screen = LockStatus(locked: false, screen_off: false)
        _ = try run(l); try check(fullCalls == 0 && keybagCalls == 0, "no attempt")
    }),
    ("check performs preflight only", {
        let l = fresh(); let r = try run(l, checkOnly: true)
        try check(r["result"] as? String == "check_passed" && preflights == 1 && fullCalls == 0, "preflight")
    }),
    ("check still tests backend access while already unlocked", {
        let l = fresh(); os["lock_state"] = 0; screen = LockStatus(locked: false, screen_off: false)
        let r = try run(l, checkOnly: true)
        try check(r["result"] as? String == "check_passed" && preflights == 1, "must not skip preflight")
        try check(fullCalls == 0 && keybagCalls == 0, "no unlock attempt")
    }),
    ("unlocked phone cannot hide a backend access failure", {
        let l = fresh(); os["lock_state"] = 0; screen = LockStatus(locked: false, screen_off: false)
        unavailable = true; let r = try run(l, checkOnly: true)
        try check(r["status"] as? Int == 6 && preflights == 1, "surface access failure")
        try check(fullCalls == 0 && keybagCalls == 0, "no unlock attempt")
        try l.withLock { try check($0.failures == 0, "no ledger rejection") }
    }),
    ("preflight failure reports failure without an attempt", {
        let l = fresh(); unavailable = true; let r = try run(l, checkOnly: true)
        try check(r["status"] as? Int == 6 && fullCalls == 0, "fail closed")
    }),
    ("native execution unavailable leaves ledger unchanged", {
        let l = fresh(); unavailable = true; let r = try run(l)
        try check(r["status"] as? Int == 6 && r["attempted"] as? Bool == false, "no attempt")
        try l.withLock { try check($0.failures == 0, "no false rejection") }
    }),
    ("failure ceiling blocks full unlock", {
        let l = fresh(); os["failed_attempts"] = 3; let r = try run(l)
        try check(r["status"] as? Int == 5 && fullCalls == 0, "failure budget")
    }),
    ("backoff blocks full unlock", {
        let l = fresh(); os["backoff_seconds"] = 60; let r = try run(l)
        try check(r["status"] as? Int == 5 && fullCalls == 0, "backoff")
    }),
    ("permanent block prevents full unlock", {
        let l = fresh(); os["permanently_blocked"] = true; let r = try run(l)
        try check(r["status"] as? Int == 5 && fullCalls == 0, "block")
    }),
    ("wrong passcode is recorded and not retried", {
        let l = fresh(); reject = true; let first = try run(l); let second = try run(l)
        try check(first["status"] as? Int == 3 && second["status"] as? Int == 4 && fullCalls == 1, "no retry")
    }),
    ("backend success must agree with live screen state", {
        let l = fresh(); falseSuccess = true; let r = try run(l)
        try check(r["status"] as? Int == 6 && r["ui_unlocked"] as? Bool == false, "screen verification")
    }),
    ("uncounted failure is not retried or recorded as wrong", {
        let l = fresh(); uncounted = true; let r = try run(l)
        try check(r["status"] as? Int == 6 && fullCalls == 1, "no retry")
        try l.withLock { try check($0.failures == 0, "no false rejection") }
    }),
    ("keybag-only mode remains unchanged", {
        let l = fresh(); _ = try run(l, dismiss: false)
        try check(keybagCalls == 1 && fullCalls == 0 && preflights == 0, "existing mode")
    }),
]
var failed = false
for (name, test) in tests {
    do { try test(); print("PASS \(name)") }
    catch { failed = true; print("FAIL \(name): \(error)") }
}
exit(failed ? 1 : 0)
