import Foundation
import IcliPrivate

/// Checks, dispatches once, then observes a transition. A GUI race remains
/// between the last check and input; UI evidence is not transaction proof.
/// This library guard is unconditional, including in DEBUG hosts.
public func performVerifiedUIAction(_ request: VerifiedUIActionRequest) -> VerifiedUIActionResult {
    var activationTarget: OpaquePointer?
    var activationError: Int32?
    defer { icli_ax_activation_target_free(activationTarget) }
    let environment = VerifiedUIActionEnvironment(
        now: { ProcessInfo.processInfo.systemUptime },
        wait: { Thread.sleep(forTimeInterval: $0) },
        context: { try verifiedUIContext(app: request.app) },
        observe: {
            let before = try verifiedUIContext(app: request.app)
            let result = try decodeBridgeJSON(
                takeCString(icli_ax_elements_json(Int32(before["pid"] as! Int), 2000)), "AX response")
            guard result["truncated"] as? Bool == false,
                  let rows = result["elements"] as? [[String: Any]] else {
                throw IcliError.failed("AX observation incomplete or truncated")
            }
            let after = try verifiedUIContext(app: request.app)
            guard NSDictionary(dictionary: before).isEqual(to: after) else {
                throw IcliError.failed("context changed during AX observation")
            }
            return VerifiedUIObservation(context: after, elements: rows.filter { $0["visible"] as? Bool == true })
        },
        hitTest: { x, y in
            let context = try verifiedUIContext(app: request.app)
            if request.method == .accessibility {
                let result = try decodeBridgeJSON(
                    takeCString(icli_ax_activation_target_hit_json(activationTarget, x, y)), "AX retained hit test")
                return result["element"] as? [String: Any] ?? [:]
            }
            let result = try decodeBridgeJSON(
                takeCString(icli_ax_element_at_json(Int32(context["pid"] as! Int), x, y)), "AX hit test")
            return result["element"] as? [String: Any] ?? [:]
        },
        dispatch: { x, y in
            if request.method == .accessibility {
                activationError = icli_ax_activation_target_perform(activationTarget)
                return activationError == 0
            }
            return icli_hid_tap(x, y)
        },
        describeError: { ($0 as? IcliError)?.message ?? $0.localizedDescription },
        prepareTarget: { original in
            guard request.method == .accessibility else { return original }
            let context = try verifiedUIContext(app: request.app)
            var report: UnsafeMutablePointer<CChar>?
            activationTarget = icli_ax_activation_target_create(Int32(context["pid"] as! Int), request.tapIdentifier, &report)
            let result = try decodeBridgeJSON(takeCString(report), "AX activation preparation")
            guard activationTarget != nil, let row = result["element"] as? [String: Any] else {
                throw IcliError.failed("direct AX activation target unavailable")
            }
            return row
        }
    )
    let executed = executeVerifiedUIAction(request, environment: environment)
    var dispatchEvidence = executed.evidence
    if let activationError { dispatchEvidence["ax_error"] = activationError }
    let result = VerifiedUIActionResult(outcome: executed.outcome, dispatchAttempted: executed.dispatchAttempted,
                                        sent: executed.sent, evidence: dispatchEvidence)
    guard result.outcome != .verified, let path = request.failureScreenshot else { return result }
    var evidence = result.evidence
    do {
        evidence["failure_screenshot"] = try takeScreenshot(path: path)
        evidence["screenshot_frontmost"] = frontmostApp()
        evidence["screenshot_note"] = "Captured after the outcome; may show a changed app or screen."
    } catch { evidence["screenshot_error"] = error.localizedDescription }
    return VerifiedUIActionResult(outcome: result.outcome, dispatchAttempted: result.dispatchAttempted,
                                  sent: result.sent, evidence: evidence)
}

private func verifiedUIContext(app: String) throws -> [String: Any] {
    try requirePointInput()
    icli_private_init()
    let lock = icli_lock_status()
    guard !lock.locked && !lock.screen_off else { throw IcliError.locked }
    let front = frontmostApp()
    guard front["verified"] as? Bool == true, front["bundle_id"] as? String == app else {
        throw IcliError.failed("intended app is not the verified foreground app")
    }
    let pid = try frontmostPID()
    var context = try decodeBridgeJSON(takeCString(icli_ui_process_identity_json(pid)), "process identity")
    let metrics = icli_screen_metrics()
    // Unlike the general metrics fallback, verified actions require an answer
    // from SpringBoard rather than guessing portrait when rotation is unknown.
    let orientation = icli_interface_degrees()
    guard orientation >= 0, metrics.orientation == orientation else {
        throw IcliError.failed("interface orientation unavailable or changing")
    }
    context.merge(["app": app, "width": metrics.width, "height": metrics.height,
                   "scale": metrics.scale, "orientation": orientation]) { _, new in new }
    let final = frontmostApp(), finalLock = icli_lock_status()
    guard final["verified"] as? Bool == true, final["bundle_id"] as? String == app,
          !finalLock.locked && !finalLock.screen_off else {
        throw IcliError.failed("foreground or interactive state changed")
    }
    return context
}
