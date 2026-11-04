import Foundation
import IcliPrivate
import UIKit

/// iOS keeps this many points of a drag before a scroll view starts moving.
private let scrollSlop = 12.0
private let strokeSeconds = 0.6
private let strokeRest = 0.15

/// A stroke's points in UI points: a quick start past the touch slop in the first
/// third of the steps, then a cubic ease in and out, so the finger is at rest when
/// it reaches the end.
private func strokePath(x1: Double, y1: Double, x2: Double, y2: Double, steps: Int) -> (xs: [Double], ys: [Double]) {
    let length = hypot(x2 - x1, y2 - y1)
    let start = length > 1 ? min(15 / length, 0.5) : 0.5
    let lead = steps / 3
    var xs: [Double] = [], ys: [Double] = []
    for step in 0 ... steps {
        let fraction: Double
        if step <= lead {
            fraction = start * Double(step) / Double(lead)
        } else {
            let t = Double(step - lead) / Double(steps - lead)
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(2 - 2 * t, 3) / 2
            fraction = start + (1 - start) * eased
        }
        xs.append(x1 + (x2 - x1) * fraction)
        ys.append(y1 + (y2 - y1) * fraction)
    }
    return (xs, ys)
}

public func swipeWithoutMomentum(
    x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double, steps: Int,
) throws -> [String: Any] {
    try requirePointInput()
    try validatePoint(x1, y1)
    try validatePoint(x2, y2)
    guard seconds.isFinite, seconds >= 0, seconds <= 60 else { throw IcliError.failed("seconds must be 0–60") }
    guard (1 ... 2000).contains(steps) else { throw IcliError.failed("steps must be 1–2000") }
    let path = strokePath(x1: x1, y1: y1, x2: x2, y2: y2, steps: max(steps, 30))
    guard icli_hid_stroke(path.xs, path.ys, Int32(path.xs.count), max(seconds, strokeSeconds), strokeRest) else {
        throw IcliError.failed("hid stroke unavailable")
    }
    return ["from": [x1, y1], "to": [x2, y2], "momentum": false]
}

public func scrollBy(direction: String, points: Double, x: Double? = nil, y: Double? = nil) throws -> [String: Any] {
    try requirePointInput()
    guard ["up", "down", "left", "right"].contains(direction) else {
        throw IcliError.failed("direction must be up, down, left or right")
    }
    guard points.isFinite, points > 0 else { throw IcliError.failed("points must be a positive distance") }
    let metrics = icli_screen_metrics()
    let vertical = direction == "up" || direction == "down"
    let length = vertical ? metrics.height : metrics.width
    let across = vertical ? metrics.width : metrics.height
    // Revealing what is further on moves the finger back towards the origin.
    let sign = direction == "down" || direction == "right" ? -1.0 : 1.0
    let along = vertical ? y : x
    let start = along.map { min(max($0 / length, 0.1), 0.9) } ?? 0.5 - 0.3 * sign
    let room = min(sign > 0 ? 0.95 - start : start - 0.05, 0.6)
    let reach = length * room - scrollSlop
    guard reach >= 20 else {
        throw IcliError.failed("no room to scroll \(direction) from there; choose a point further from the screen's edge")
    }
    let strokes = Int(ceil(points / reach))
    let end = start + sign * (scrollSlop + points / Double(strokes)) / length
    let side = (vertical ? x : y).map { min(max($0 / across, 0.08), 0.92) } ?? 0.5
    let (x1, y1, x2, y2) = vertical
        ? (side * across, start * length, side * across, end * length)
        : (start * length, side * across, end * length, side * across)
    try validatePoint(x1, y1)
    try validatePoint(x2, y2)
    let path = strokePath(x1: x1, y1: y1, x2: x2, y2: y2, steps: 30)
    for _ in 0 ..< strokes {
        guard icli_hid_stroke(path.xs, path.ys, Int32(path.xs.count), strokeSeconds, strokeRest) else {
            throw IcliError.failed("hid stroke unavailable")
        }
    }
    return ["direction": direction, "points": points, "strokes": strokes]
}

/// What is on screen and where, to tell whether a stroke moved anything.
private func screenSignature(source: ElementSource, languages: [String]) throws -> String {
    if source == .ocr {
        let blocks = try recognizeScreen(languages: languages, minConfidence: 0.3)["blocks"] as? [[String: Any]] ?? []
        return blocks.map { ($0["text"] as? String ?? "") }.joined(separator: "\n")
    }
    let elements = try uiElements(maxElements: 2000)["elements"] as? [[String: Any]] ?? []
    return elements.map { element in
        let y = elementCoordinate(element["y"]).map { Int($0.rounded()) } ?? 0
        let x = elementCoordinate(element["x"]).map { Int($0.rounded()) } ?? 0
        return "\(element["label"] as? String ?? "")|\(element["value"] as? String ?? "")|\(x)|\(y)"
    }.joined(separator: "\n")
}

/// The signature once two readings in a row agree: content rubber-banding at its
/// end moves after the finger lifts.
private func settledSignature(source: ElementSource, languages: [String]) throws -> String {
    var last = try screenSignature(source: source, languages: languages)
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.15)
        let next = try screenSignature(source: source, languages: languages)
        if next == last { return next }
        last = next
    }
    return last
}

public func scrollToElement(
    _ selector: ElementSelector, direction: String, maxScrolls: Int, x: Double?, y: Double?,
    source: ElementSource = .ax, languages: [String] = ["zh-Hans", "en-US"],
) throws -> [String: Any] {
    try requirePointInput()
    guard (1 ... 100).contains(maxScrolls) else { throw IcliError.failed("max-scrolls must be 1–100") }
    let metrics = icli_screen_metrics()
    let stroke = (direction == "left" || direction == "right" ? metrics.width : metrics.height) * 0.45
    var scrolls = 0
    while true {
        let (hits, used) = try selectedElements(selector, source: source, languages: languages)
        let best = selector.indexIsExplicit
            ? (hits.indices.contains(selector.index) ? [hits[selector.index]] : [])
            : bestMatches(hits, selector)
        if let element = best.first {
            var result: [String: Any] = ["found": true, "element": element, "scrolls": scrolls, "matches": best.count]
            if source != .ax { result["source"] = used.rawValue }
            return result
        }
        if scrolls == maxScrolls {
            throw IcliError.commandFailed([
                "error": "not_found", "reason": "max_scrolls", "scrolls": scrolls, "status": 1,
                "message": "scrolled \(direction) \(scrolls) times without finding it; raise --max-scrolls or try the other direction",
            ])
        }
        let before = try settledSignature(source: source, languages: languages)
        _ = try scrollBy(direction: direction, points: stroke, x: x, y: y)
        scrolls += 1
        if try settledSignature(source: source, languages: languages) == before {
            throw IcliError.commandFailed([
                "error": "not_found", "reason": "end_of_content", "scrolls": scrolls, "status": 1,
                "message": "reached the end of the content scrolling \(direction) without finding it; try the other direction",
            ])
        }
    }
}

private func keyboardIsShown() -> Bool {
    // UIAccessibilityTraitKeyboardKey
    let elements = (try? uiElements(maxElements: 2000, scope: .app)["elements"] as? [[String: Any]]) ?? []
    return elements.contains { ($0["traits"] as? Int ?? 0) & 0x20 != 0 }
}

/// Selects everything in the focused field and deletes it.
public func clearFocusedField() throws {
    _ = try pressKey("cmd+a")
    _ = try pressKey("delete")
}

public func fillField(
    _ selector: ElementSelector, value: String?, submit: Bool,
    source: ElementSource = .ax, languages: [String] = ["zh-Hans", "en-US"],
) throws -> [String: Any] {
    let tapped = try tapElement(selector, source: source, languages: languages)
    // Keys sent before the field takes focus are lost; a hardware keyboard shows no keys.
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var keyboard = keyboardIsShown()
    while !keyboard, ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.1)
        keyboard = keyboardIsShown()
    }
    try clearFocusedField()
    if let value, !value.isEmpty { _ = try pasteText(value) }
    if submit { _ = try pressKey("return") }
    return ["filled": true, "element": tapped["element"] ?? [:], "keyboard_seen": keyboard, "sent": value?.count ?? 0]
}

/// Puts the software keyboard away. The key toggles it, so it is sent only when
/// the keyboard is up, and the keyboard going away is what confirms it.
public func hideKeyboard() throws -> [String: Any] {
    guard keyboardIsShown() else { return ["hidden": true, "was_shown": false] }
    // Consumer page: AC Eject, which iOS answers by toggling the on-screen keyboard.
    guard icli_hid_key(12, 184, true) else { throw IcliError.failed("hid key unavailable") }
    Thread.sleep(forTimeInterval: 0.08)
    guard icli_hid_key(12, 184, false) else { throw IcliError.failed("hid key unavailable") }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while keyboardIsShown() {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw IcliError.failed("the keyboard stayed on screen")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return ["hidden": true, "was_shown": true]
}

/// Leaves the screen: its back button when it has one, otherwise a swipe in from
/// the left edge, which may do nothing.
public func goBack() throws -> [String: Any] {
    try requirePointInput()
    let elements = try uiElements(maxElements: 2000, scope: .app)["elements"] as? [[String: Any]] ?? []
    let buttons = elements.filter { $0["role"] as? String == "button" && $0["enabled"] as? Bool != false }
    // UIAccessibilityTraitBackButton, private; a navigation bar's button is labelled with the previous screen's title.
    let marked = buttons.first { ($0["traits"] as? Int ?? 0) & 0x800_0000 != 0 || $0["identifier"] as? String == "BackButton" }
    let named = buttons.first { element in
        let label = (element["label"] as? String ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label == "back" || label == "go back"
    }
    if let button = marked ?? named,
       let x = elementCoordinate(button["x"]), let y = elementCoordinate(button["y"])
    {
        _ = try tap(x: x, y: y)
        return ["method": "button", "element": button]
    }
    let metrics = icli_screen_metrics()
    guard icli_hid_edge_swipe(metrics.width * 0.004, metrics.height / 2, metrics.width * 0.7, metrics.height / 2, 0.3, 20) else {
        throw IcliError.failed("hid swipe unavailable")
    }
    return ["method": "edge_swipe"]
}

/// Prompts only the device's owner may answer, as (kind, lowercase phrases).
private let humanPrompts: [(kind: String, phrases: [String])] = [
    ("passcode", ["enter iphone passcode", "enter ipad passcode", "enter your passcode"]),
    ("face_id", ["look at your iphone", "look at your ipad", "confirm with face id"]),
    ("touch_id", ["place your finger", "rest your finger", "confirm with touch id", "touch id for "]),
    ("apple_account", ["apple account password", "enter the password for", "sign in with your apple account"]),
    ("vpn", ["would like to add vpn configuration"]),
    ("allow_paste", ["would like to paste from", "don't allow paste"]),
    ("profile", ["install profile"]),
    ("purchase", ["double-click to pay", "double click to pay", "double-click to install", "double click to install",
                  "confirm with side button", "confirm with top button"]),
]
private let acceptButtons = [
    "allow while using app", "while using the app", "allow", "allow full access", "allow access to all photos",
    "allow all", "only this time", "ok", "continue", "turn on", "open", "yes",
]
private let dismissButtons = ["don't allow", "ask app not to track", "not now", "cancel", "close", "no", "later", "dismiss", "ignore", "deny"]

private func alertText(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{2019}", with: "'")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

/// System alerts belong to SpringBoard and sit over an app whose own tree does
/// not list them, so SpringBoard's tree comes first.
private func alertElements() throws -> [[String: Any]] {
    var trees: [[[String: Any]]] = []
    let shell = try listProcesses(filter: SystemShell.processName)["processes"] as? [[String: Any]] ?? []
    if let pid = shell.first(where: { $0["name"] as? String == SystemShell.processName })?["pid"] as? Int,
       let tree = try? decodeBridgeJSON(takeCString(icli_ax_elements_json(Int32(pid), 2000)), "AX response")
    {
        trees.append((tree["elements"] as? [[String: Any]] ?? []).filter { $0["visible"] as? Bool == true })
    }
    if let tree = try? uiElements(maxElements: 2000) {
        trees.append(tree["elements"] as? [[String: Any]] ?? [])
    }
    return trees.flatMap { $0 }
}

/// The text an element list or OCR result shows.
func screenText(_ list: Any?) -> [String] {
    (list as? [[String: Any]] ?? []).flatMap { [$0["label"], $0["value"], $0["text"]].compactMap { $0 as? String } }
}

/// Which owner-only prompt this text shows, if any.
func promptKind(in text: [String]) -> String? {
    let lines = text.map(alertText)
    return humanPrompts.first { prompt in
        lines.contains { line in prompt.phrases.contains { line.contains($0) } }
    }?.kind
}

/// Whether a prompt only the device's owner may answer is on screen. These often
/// belong to a process with no tree to read, so text recognition looks when the
/// trees show none, unless the source says otherwise.
public func currentPrompt(source: ElementSource = .any, languages: [String] = ["en-US"]) throws -> [String: Any] {
    if source != .ocr, let kind = promptKind(in: screenText(try alertElements())) {
        return ["human_required": true, "kind": kind, "source": "ax"]
    }
    if source != .ax {
        let blocks = try recognizeScreen(languages: languages, minConfidence: 0.3)["blocks"]
        if let kind = promptKind(in: screenText(blocks)) {
            return ["human_required": true, "kind": kind, "source": "ocr"]
        }
    }
    return ["human_required": false]
}

/// Moves the system answers to a finger, in fractions of the screen, as (from, to,
/// seconds, seconds resting at the end).
public func systemGesture(_ name: String) throws -> [String: Any] {
    try requirePointInput()
    let metrics = icli_screen_metrics()
    let path: (fromX: Double, fromY: Double, toX: Double, toY: Double, seconds: Double, rest: Double)
    switch name {
    case "home":
        _ = try pressButton("home")
        return ["gesture": name, "method": "button"]
    case "app-switcher": path = (0.5, 0.999, 0.5, 0.6, 0.45, 0.7)
    case "control-center": path = (0.97, 0.001, 0.9, 0.5, 0.3, 0)
    case "notification-center":
        let x = UIDevice.current.userInterfaceIdiom == .pad ? 0.25 : 0.3
        path = (x, 0.001, x, 0.6, 0.3, 0)
    case "spotlight": path = (0.5, 0.3, 0.5, 0.55, 0.3, 0)
    default:
        throw IcliError.failed("gesture must be home, app-switcher, control-center, notification-center or spotlight")
    }
    let steps = 20
    let xs = (0 ... steps).map { path.fromX + (path.toX - path.fromX) * Double($0) / Double(steps) }.map { $0 * metrics.width }
    let ys = (0 ... steps).map { path.fromY + (path.toY - path.fromY) * Double($0) / Double(steps) }.map { $0 * metrics.height }
    guard icli_hid_stroke(xs, ys, Int32(xs.count), path.seconds, path.rest) else {
        throw IcliError.failed("hid stroke unavailable")
    }
    return ["gesture": name, "method": "touch"]
}

private func alertTextElements() throws -> [[String: Any]] {
    let blocks = try recognizeScreen(languages: ["en-US"], minConfidence: 0.3)["blocks"] as? [[String: Any]] ?? []
    return blocks.map { block in
        var element = block
        element["label"] = block["text"]
        return element
    }
}

public func answerAlert(action: String?, button: String?) throws -> [String: Any] {
    try requirePointInput()
    guard (action == nil) != (button == nil), action == nil || action == "accept" || action == "dismiss" else {
        throw IcliError.failed("give accept, dismiss or --button")
    }
    let wanted = button.map { [alertText($0)] } ?? (action == "accept" ? acceptButtons : dismissButtons)
    func matches(in elements: [[String: Any]]) -> [[String: Any]] {
        elements.filter { wanted.contains(alertText($0["label"] as? String ?? "")) && $0["clickable"] as? Bool != false }
    }
    let tree = try alertElements()
    let usesText = matches(in: tree).isEmpty
    let elements = usesText ? try alertTextElements() : tree
    let source = usesText ? "ocr" : "ax"
    if let kind = promptKind(in: screenText(elements)) {
        throw IcliError.commandFailed([
            "error": "human_required", "kind": kind, "status": 1,
            "message": "only the device's owner may answer this prompt; nothing was tapped",
        ])
    }
    // The list is in order of preference: Allow While Using App before Allow.
    let candidates = matches(in: elements)
    let hit = wanted.compactMap { name in
        candidates.first { alertText($0["label"] as? String ?? "") == name }
    }.first
    guard let hit else {
        throw IcliError.commandFailed([
            "error": "no_alert", "status": 1,
            "message": "no matching alert button on screen; nothing was tapped",
        ])
    }
    guard let x = elementCoordinate(hit["x"]), let y = elementCoordinate(hit["y"]) else {
        throw IcliError.failed("alert button has no tap point")
    }
    _ = try tap(x: x, y: y)
    return ["tapped": true, "button": hit["label"] ?? "", "x": x, "y": y, "source": source]
}
