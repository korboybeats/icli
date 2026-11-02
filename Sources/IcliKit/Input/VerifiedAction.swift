import Foundation

/// Exact accessibility identifiers only; unlike ElementSelector, labels are
/// never accepted as identifiers and an index cannot hide ambiguous matches.
public enum VerifiedUICondition {
    case appeared(String)
    case disappeared(String)
    case valueChanged(String)

    var identifier: String {
        switch self {
        case let .appeared(id), let .disappeared(id), let .valueChanged(id): return id
        }
    }

    var name: String {
        switch self {
        case .appeared: return "appeared"
        case .disappeared: return "disappeared"
        case .valueChanged: return "value_changed"
        }
    }
}

public enum VerifiedUIActionMethod: String {
    case touch
    case accessibility
}

public struct VerifiedUIActionRequest {
    public let app: String
    public let tapIdentifier: String
    public let condition: VerifiedUICondition
    public let timeout: TimeInterval
    public let interval: TimeInterval
    public let failureScreenshot: String?
    public let method: VerifiedUIActionMethod

    public init(app: String, tapIdentifier: String, condition: VerifiedUICondition,
                timeout: TimeInterval = 10, interval: TimeInterval = 0.2,
                failureScreenshot: String? = nil, method: VerifiedUIActionMethod = .touch) {
        self.app = app
        self.tapIdentifier = tapIdentifier
        self.condition = condition
        self.timeout = timeout
        self.interval = interval
        self.failureScreenshot = failureScreenshot
        self.method = method
    }
}

public enum VerifiedUIActionOutcome: String {
    case refused
    case verified
    case sentUnconfirmed = "sent_unconfirmed"
}

public struct VerifiedUIActionResult {
    public let outcome: VerifiedUIActionOutcome
    public let dispatchAttempted: Bool
    /// The selected dispatch API returned success. Visible results are verified separately.
    public let sent: Bool
    public let evidence: [String: Any]

    public var payload: [String: Any] {
        evidence.merging([
            "outcome": outcome.rawValue, "dispatch_attempted": dispatchAttempted,
            "sent": sent, "verified": outcome == .verified,
            "status": outcome == .verified ? 0 : (dispatchAttempted ? 3 : 1),
        ]) { _, value in value }
    }
}

// All device reads and the sole dispatch live behind this small boundary so
// race/failure tests execute the same engine without sending real input.
struct VerifiedUIObservation {
    let context: [String: Any]
    let elements: [[String: Any]]
}

struct VerifiedUIActionEnvironment {
    var now: () -> TimeInterval
    var wait: (TimeInterval) -> Void
    var context: () throws -> [String: Any]
    var observe: () throws -> VerifiedUIObservation
    var hitTest: (Double, Double) throws -> [String: Any]
    var dispatch: (Double, Double) throws -> Bool
    var describeError: (Error) -> String = { $0.localizedDescription }
    var prepareTarget: ([String: Any]) throws -> [String: Any] = { $0 }
}

private struct VerificationRefusal: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func requireVerification(_ condition: Bool, _ reason: String) throws {
    if !condition { throw VerificationRefusal(reason) }
}

private func equalJSON(_ left: Any, _ right: Any) -> Bool {
    // AX values are JSON scalars, including numbers; don't conflate absent and
    // empty values or stringify numbers for transition comparisons.
    NSDictionary(dictionary: ["v": left]).isEqual(to: ["v": right])
}

private func exactMatches(_ id: String, _ rows: [[String: Any]]) -> [[String: Any]] {
    rows.filter { $0["identifier"] as? String == id && $0["visible"] as? Bool == true }
}

private func targetSignature(_ row: [String: Any]) -> [String: Any] {
    row.filter { ["identifier", "label", "value", "role", "traits", "frame", "x", "y",
                  "enabled", "clickable", "visible"].contains($0.key) }
}

private func target(_ id: String, in observation: VerifiedUIObservation) throws -> [String: Any] {
    let hits = exactMatches(id, observation.elements)
    try requireVerification(hits.count == 1, hits.isEmpty ? "target_missing" : "target_ambiguous")
    let row = hits[0]
    try requireVerification(row["enabled"] as? Bool == true && row["clickable"] as? Bool == true,
                            "target_not_enabled_or_clickable")
    guard let x = row["x"] as? Double, let y = row["y"] as? Double,
          let frame = row["frame"] as? [String: Double],
          let fx = frame["x"], let fy = frame["y"], let w = frame["width"], let h = frame["height"],
          let width = observation.context["width"] as? Double,
          let height = observation.context["height"] as? Double else {
        throw VerificationRefusal("target_geometry_unavailable")
    }
    try requireVerification([x, y, fx, fy, w, h, width, height].allSatisfy(\.isFinite)
        && w > 0 && h > 0 && x >= max(0, fx) && y >= max(0, fy)
        && x < min(width, fx + w) && y < min(height, fy + h), "target_point_outside_visible_frame")
    return row
}

private func conditionRows(_ condition: VerifiedUICondition, _ rows: [[String: Any]]) throws -> [[String: Any]] {
    let hits = exactMatches(condition.identifier, rows)
    try requireVerification(hits.count <= 1, "expectation_ambiguous")
    return hits
}

private func requireBaseline(_ condition: VerifiedUICondition, _ rows: [[String: Any]]) throws -> [[String: Any]] {
    let hits = try conditionRows(condition, rows)
    switch condition {
    case .appeared: try requireVerification(hits.isEmpty, "expectation_already_present")
    case .disappeared: try requireVerification(hits.count == 1, "expectation_already_absent")
    case .valueChanged:
        try requireVerification(hits.count == 1 && hits[0]["value"] != nil, "expectation_value_unavailable")
    }
    return hits
}

private func transitioned(_ condition: VerifiedUICondition, before: [[String: Any]], after: [[String: Any]]) -> Bool {
    switch condition {
    case .appeared: return after.count == 1
    case .disappeared: return after.isEmpty
    case .valueChanged:
        guard after.count == 1, let old = before.first?["value"], let new = after[0]["value"] else { return false }
        return !equalJSON(old, new)
    }
}

// A multiset diff retains duplicate rows and caps both the count and text in
// evidence. It is a difference of observations, not a causal event history.
private func compactRows(_ rows: [[String: Any]]) -> [[String: Any]] {
    rows.map { row in
        var result: [String: Any] = [:]
        for key in ["identifier", "label", "value", "role"] {
            if let text = row[key] as? String { result[key] = String(text.prefix(256)) }
            else if let value = row[key] { result[key] = value }
        }
        return result
    }
}

private func difference(_ before: [[String: Any]], _ after: [[String: Any]]) -> [String: Any] {
    var unmatched = compactRows(before)
    var added: [[String: Any]] = []
    for row in compactRows(after) {
        if let index = unmatched.firstIndex(where: { equalJSON($0, row) }) { unmatched.remove(at: index) }
        else { added.append(row) }
    }
    return ["added": Array(added.prefix(20)), "removed": Array(unmatched.prefix(20)),
            "truncated": added.count > 20 || unmatched.count > 20]
}

func executeVerifiedUIAction(_ request: VerifiedUIActionRequest,
                             environment env: VerifiedUIActionEnvironment) -> VerifiedUIActionResult {
    let start = env.now()
    let deadline = start + request.timeout
    var attempted = false, sent = false
    var dispatchTime: TimeInterval?
    var before: VerifiedUIObservation?, latest: VerifiedUIObservation?
    var evidence: [String: Any] = ["app": request.app, "tap_identifier": request.tapIdentifier,
                                 "method": request.method.rawValue,
                                 "condition": ["kind": request.condition.name, "identifier": request.condition.identifier]]

    func finish(_ outcome: VerifiedUIActionOutcome, _ reason: String) -> VerifiedUIActionResult {
        evidence["reason"] = reason
        evidence["timing_ms"] = ["total": Int(max(0, env.now() - start) * 1000),
                                 "before_dispatch": Int(max(0, (dispatchTime ?? env.now()) - start) * 1000),
                                 "after_dispatch": Int(max(0, dispatchTime.map { env.now() - $0 } ?? 0) * 1000)]
        if let before {
            evidence["context"] = before.context
            evidence["baseline"] = compactRows(exactMatches(request.condition.identifier, before.elements))
            if let latest {
                evidence["observed"] = compactRows(exactMatches(request.condition.identifier, latest.elements))
                evidence["ui_diff"] = difference(before.elements, latest.elements)
            }
        }
        return VerifiedUIActionResult(outcome: outcome, dispatchAttempted: attempted, sent: sent, evidence: evidence)
    }

    do {
        try requireVerification(!request.app.isEmpty && !request.tapIdentifier.isEmpty && !request.condition.identifier.isEmpty,
                                "app_and_identifiers_required")
        try requireVerification(request.timeout.isFinite && (0.1 ... 60).contains(request.timeout)
            && request.interval.isFinite && (0.1 ... 5).contains(request.interval), "invalid_timeout_or_interval")
        let initial = try env.observe()
        before = initial; latest = initial
        try requireVerification(initial.context["app"] as? String == request.app, "foreground_app_mismatch")
        let first = try target(request.tapIdentifier, in: initial)
        let baseline = try requireBaseline(request.condition, initial.elements)
        let prepared = try env.prepareTarget(first)
        try requireVerification(equalJSON(targetSignature(first), targetSignature(prepared)), "target_changed_during_preparation")

        let final = try env.observe()
        latest = final
        try requireVerification(equalJSON(initial.context, final.context), "context_changed_before_dispatch")
        let last = try target(request.tapIdentifier, in: final)
        try requireVerification(equalJSON(targetSignature(first), targetSignature(last)), "target_changed_before_dispatch")
        let finalBaseline = try requireBaseline(request.condition, final.elements)
        if case .valueChanged = request.condition {
            try requireVerification(equalJSON(baseline[0]["value"]!, finalBaseline[0]["value"]!),
                                    "expectation_changed_before_dispatch")
        }
        let x = last["x"] as! Double, y = last["y"] as! Double
        let hit = try env.hitTest(x, y)
        try requireVerification(equalJSON(targetSignature(last), targetSignature(hit)), "target_occluded_or_changed")
        try requireVerification(equalJSON(final.context, try env.context()), "context_changed_before_dispatch")
        try requireVerification(env.now() < deadline, "deadline_before_dispatch")
        evidence["target"] = ["identifier": request.tapIdentifier, "x": x, "y": y, "frame": last["frame"]!]

        // Mark before entering HID: an error can occur after finger-down. Never
        // retry, and never describe a failed/throwing dispatch as a refusal.
        attempted = true; dispatchTime = env.now()
        sent = try env.dispatch(x, y)
        try requireVerification(sent, "dispatch_incomplete")
        while env.now() < deadline {
            let observation = try env.observe()
            latest = observation
            try requireVerification(equalJSON(final.context, observation.context), "context_changed_after_dispatch")
            let hits = try conditionRows(request.condition, observation.elements)
            if env.now() <= deadline && transitioned(request.condition, before: baseline, after: hits) {
                return finish(.verified, "transition_observed")
            }
            let remaining = deadline - env.now()
            if remaining > 0 { env.wait(min(request.interval, remaining)) }
        }
        return finish(.sentUnconfirmed, "timeout")
    } catch {
        return finish(attempted ? .sentUnconfirmed : .refused, env.describeError(error))
    }
}
