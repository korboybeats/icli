import Foundation

func row(_ id: String, value: String = "", x: Double = 50) -> [String: Any] {
    ["identifier": id, "label": id, "value": value, "role": "button", "traits": 1,
     "x": x, "y": 50.0, "frame": ["x": 0.0, "y": 0.0, "width": 100.0, "height": 100.0],
     "enabled": true, "clickable": true, "visible": true]
}

let context: [String: Any] = ["app": "test", "pid": 1, "started_seconds": 10,
                            "orientation": 0, "width": 400.0, "height": 800.0]
let button = row("tap")
let ready = row("ready")
let oldValue = row("value", value: "old")
let newValue = row("value", value: "new")
var passed = 0

func check(_ name: String, condition: VerifiedUICondition = .appeared("ready"),
           rows: [[[String: Any]]] = [[button], [button], [button, ready]],
           contexts: [[String: Any]] = [], hit: [String: Any]? = nil,
           finalContext: [String: Any] = context, dispatchOK: Bool = true,
           throwingDispatch: Bool = false, throwingObservation: Int? = nil,
           observationCost: Double = 0, timeout: Double = 1,
           outcome: VerifiedUIActionOutcome = .verified, attempts: Int = 1,
           reason: String? = nil, method: VerifiedUIActionMethod = .touch,
           prepared: [String: Any]? = nil, preparationFailure: Bool = false) {
    var clock = 0.0, reads = 0, sends = 0
    let env = VerifiedUIActionEnvironment(now: { clock }, wait: { clock += $0 }, context: { finalContext },
        observe: {
            defer { reads += 1; clock += observationCost }
            if reads == throwingObservation { throw NSError(domain: "AX unavailable", code: 1) }
            return VerifiedUIObservation(context: contexts.isEmpty ? context : contexts[min(reads, contexts.count - 1)],
                                         elements: rows[min(reads, rows.count - 1)])
        }, hitTest: { _, _ in hit ?? button }, dispatch: { _, _ in
            sends += 1
            if throwingDispatch { throw NSError(domain: "HID partial", code: 1) }
            return dispatchOK
        }, prepareTarget: { row in
            if preparationFailure { throw NSError(domain: "activation preparation unavailable", code: 1) }
            return prepared ?? row
        })
    let result = executeVerifiedUIAction(VerifiedUIActionRequest(app: "test", tapIdentifier: "tap",
        condition: condition, timeout: timeout, method: method), environment: env)
    precondition(result.outcome == outcome && sends == attempts, "\(name): \(result.payload) sends=\(sends)")
    precondition(result.dispatchAttempted == (attempts > 0), name)
    if let reason { precondition(result.evidence["reason"] as? String == reason, "\(name): \(result.payload)") }
    precondition(JSONSerialization.isValidJSONObject(result.payload), name)
    precondition(result.evidence["method"] as? String == method.rawValue, name)
    if let diff = result.evidence["ui_diff"] as? [String: Any] {
        for key in ["added", "removed"] {
            let rows = diff[key] as! [[String: Any]]
            precondition(rows.count <= 20, name)
            precondition(rows.flatMap { $0.values.compactMap { $0 as? String } }.allSatisfy { $0.count <= 256 }, name)
        }
    }
    passed += 1
    print("PASS \(name)")
}

check("appeared")
check("disappeared", condition: .disappeared("ready"), rows: [[button, ready], [button, ready], [button]])
check("value changed", condition: .valueChanged("value"), rows: [[button, oldValue], [button, oldValue], [button, newValue]])
check("already present", rows: [[button, ready]], outcome: .refused, attempts: 0, reason: "expectation_already_present")
check("already absent", condition: .disappeared("ready"), rows: [[button]], outcome: .refused, attempts: 0)
check("missing value", condition: .valueChanged("value"), rows: [[button]], outcome: .refused, attempts: 0)
check("duplicate target", rows: [[button, button]], outcome: .refused, attempts: 0, reason: "target_ambiguous")
check("label is not identifier", rows: [[row("different").merging(["label": "tap"]) { _, new in new }]],
      outcome: .refused, attempts: 0, reason: "target_missing")
check("disabled", rows: [[button.merging(["enabled": false]) { _, new in new }]], outcome: .refused, attempts: 0)
check("offscreen point", rows: [[row("tap", x: 450)]], outcome: .refused, attempts: 0)
check("nonfinite point", rows: [[row("tap", x: .nan)]], outcome: .refused, attempts: 0)
check("moving target", rows: [[button], [row("tap", x: 60)]], outcome: .refused, attempts: 0,
      reason: "target_changed_before_dispatch")
check("occluded target", hit: row("overlay"), outcome: .refused, attempts: 0, reason: "target_occluded_or_changed")
check("PID changed", contexts: [context, context.merging(["pid": 2]) { _, new in new }], outcome: .refused, attempts: 0)
check("PID reused", contexts: [context, context.merging(["started_seconds": 20]) { _, new in new }], outcome: .refused, attempts: 0)
check("rotation changed", contexts: [context, context.merging(["orientation": 90]) { _, new in new }], outcome: .refused, attempts: 0)
check("last context changed", finalContext: context.merging(["pid": 2]) { _, new in new }, outcome: .refused, attempts: 0)
check("baseline appeared during checks", rows: [[button], [button, ready]], outcome: .refused, attempts: 0)
check("value changed before tap", condition: .valueChanged("value"), rows: [[button, oldValue], [button, newValue]],
      outcome: .refused, attempts: 0, reason: "expectation_changed_before_dispatch")
check("expectation ambiguous", rows: [[button], [button], [button, ready, ready]], outcome: .sentUnconfirmed)
check("timeout sends once", rows: [[button]], outcome: .sentUnconfirmed, reason: "timeout")
check("unchanged value times out", condition: .valueChanged("value"), rows: [[button, oldValue]], outcome: .sentUnconfirmed)
check("value disappears is not change", condition: .valueChanged("value"), rows: [[button, oldValue], [button, oldValue], [button]],
      outcome: .sentUnconfirmed)
check("slow result", rows: [[button], [button], [button], [button], [button, ready]])
check("HID returns false", dispatchOK: false, outcome: .sentUnconfirmed, reason: "dispatch_incomplete")
check("partial HID throw", throwingDispatch: true, outcome: .sentUnconfirmed)
check("AX failure before dispatch", throwingObservation: 1, outcome: .refused, attempts: 0)
check("AX failure after dispatch", throwingObservation: 2, outcome: .sentUnconfirmed)
check("foreground lost after dispatch", contexts: [context, context, context.merging(["app": "other"]) { _, new in new }],
      outcome: .sentUnconfirmed)
check("prep exceeded deadline", observationCost: 0.6, outcome: .refused, attempts: 0, reason: "deadline_before_dispatch")
check("observation exceeded deadline", observationCost: 0.4, outcome: .sentUnconfirmed, reason: "timeout")
check("invalid timeout", timeout: .nan, outcome: .refused, attempts: 0)
check("bounded diff", rows: [[button], [button], [button, ready] + (0..<50).map { row("extra\($0)") }])
check("direct activation succeeds", method: .accessibility)
check("direct activation failure never falls back", dispatchOK: false, outcome: .sentUnconfirmed,
      method: .accessibility)
check("retained target changed during preparation", outcome: .refused, attempts: 0,
      reason: "target_changed_during_preparation", method: .accessibility, prepared: row("tap", x: 60))
check("activation preparation error refuses", outcome: .refused, attempts: 0,
      method: .accessibility, preparationFailure: true)
print("PASS \(passed) verified action engine cases")
