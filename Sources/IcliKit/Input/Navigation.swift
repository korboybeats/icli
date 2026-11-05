import Foundation
import IcliPrivate
import UIKit

/// How far a scroll view's pan runs behind the finger, measured with the stroke
/// below: a stroke of this plus n points scrolls n, to within a point.
private let scrollSlop = 11.0
private let strokeStep = 0.01

/// A stroke that lands where it should, with no fling, as distances along the line:
/// - to 9 points at once, then half a point a step to 13, so the pan starts at the
///   same place each time. Stopping at 11 sometimes lost a whole step of the body.
/// - the rest at up to 160 points a step (16,000 points a second).
/// - 2 points over 8 steps. UIKit takes its fling speed from the last moves it sees,
///   so these have to be real moves: a hold, or moves on the spot, still flung after
///   a fast body, and 3 steps were too few.
/// 150 strokes of 30, 200 and 500 points on TestHost's list were all within a point.
private func strokePath(x1: Double, y1: Double, x2: Double, y2: Double) -> (xs: [Double], ys: [Double], seconds: Double) {
    let length = hypot(x2 - x1, y2 - y1)
    let tail = 2.0, slopEnd = 13.0, bodyEnd = max(length - tail, 0)
    var distances = [0.0]
    if bodyEnd > slopEnd {
        distances += [4.5, 9]
        distances += stride(from: 9.5, through: slopEnd, by: 0.5)
        let span = bodyEnd - slopEnd
        let body = max(3, Int((span * 1.5 / 160).rounded(.up)))
        distances += (1 ... body).map { step in
            let t = Double(step) / Double(body)
            return slopEnd + span * t * t * (3 - 2 * t)
        }
    } else if bodyEnd > 0 {
        let body = max(4, Int((bodyEnd / 2).rounded(.up)))
        distances += (1 ... body).map { bodyEnd * Double($0) / Double(body) }
    }
    distances += (1 ... 8).map { bodyEnd + (length - bodyEnd) * Double($0) / 8 }
    let unitX = length > 0 ? (x2 - x1) / length : 0, unitY = length > 0 ? (y2 - y1) / length : 0
    return (distances.map { x1 + unitX * $0 }, distances.map { y1 + unitY * $0 }, strokeStep * Double(distances.count - 1))
}

public func swipeWithoutMomentum(
    x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double, steps: Int,
) throws -> [String: Any] {
    try requirePointInput()
    try validatePoint(x1, y1)
    try validatePoint(x2, y2)
    guard seconds.isFinite, seconds >= 0, seconds <= 60 else { throw IcliError.failed("seconds must be 0–60") }
    guard (1 ... 2000).contains(steps) else { throw IcliError.failed("steps must be 1–2000") }
    let path = strokePath(x1: x1, y1: y1, x2: x2, y2: y2)
    guard icli_hid_stroke(path.xs, path.ys, Int32(path.xs.count), max(seconds, path.seconds), 0) else {
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
    let path = strokePath(x1: x1, y1: y1, x2: x2, y2: y2)
    for index in 0 ..< strokes {
        // A stroke leaves the content drifting for a moment: back to back, each sideways
        // stroke after the first scrolled a point too far. A 30 ms pause ends that;
        // waiting for frames to stop cannot, as TestHost never stopped drawing.
        if index > 0 { Thread.sleep(forTimeInterval: 0.03) }
        guard icli_hid_stroke(path.xs, path.ys, Int32(path.xs.count), path.seconds, 0) else {
            throw IcliError.failed("hid stroke unavailable")
        }
    }
    return ["direction": direction, "points": points, "strokes": strokes]
}

/// Runs `body` again while RunningBoard is between two focal apps, which it can be
/// for a few hundred ms (see `unverifiedFrontmost`), so that one moment fails nothing.
private func throughAppSwitch<T>(_ body: () throws -> T) throws -> T {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while true {
        do {
            return try body()
        } catch let IcliError.failed(message)
            where message == unverifiedFrontmost && ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.03)
        }
    }
}

/// What is on screen and where, to tell whether a stroke moved anything.
private func screenSignature(source: ElementSource, languages: [String]) throws -> String {
    try throughAppSwitch { try currentSignature(source: source, languages: languages) }
}

private func currentSignature(source: ElementSource, languages: [String]) throws -> String {
    if source == .ocr {
        let blocks = try recognizeScreen(languages: languages, minConfidence: 0.3)["blocks"] as? [[String: Any]] ?? []
        return blocks.map { ($0["text"] as? String ?? "") }.joined(separator: "\n")
    }
    return screenSignature(of: try uiElements(maxElements: 2000)["elements"] as? [[String: Any]] ?? [])
}

private func screenSignature(of elements: [[String: Any]]) -> String {
    elements.map { element in
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

/// One reading of the accessibility tree: what a selector looks through, and the
/// signature that tells whether anything moved.
private struct ScreenReading {
    let elements: [[String: Any]]
    let signature: String

    init() throws {
        let result = try throughAppSwitch { try uiElements(maxElements: 2000) }
        guard result["truncated"] as? Bool != true else {
            throw IcliError.failed("AX query was truncated; narrow the screen before selecting an element")
        }
        elements = result["elements"] as? [[String: Any]] ?? []
        signature = screenSignature(of: elements)
    }
}

/// Reads the screen once the page action's 200 ms animation has finished: a reading
/// that differs from `before`, agrees with the one before it, and had no new frame
/// during it, since mid-swipe the Home Screen's tree holds still while its pages
/// move. Where frames never stop (a video) several agreeing readings end the wait.
/// Reading throughout is what makes this quick, 30 ms a read where a read after
/// waiting costs 50. Nil when nothing changed within a second.
private func readingAfterChange(from before: String, frames: inout FrameGate) throws -> ScreenReading? {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    _ = frames.wait(limit: 0.15, interval: 0, since: 0)
    var last = before, agreeing = 0
    while true {
        frames.mark()
        let next = try ScreenReading()
        let changed = next.signature != before
        agreeing = changed && next.signature == last ? agreeing + 1 : 0
        if agreeing >= 4 || (agreeing > 0 && (!frames.active || frames.isStillSinceMark)) { return next }
        last = next.signature
        guard ProcessInfo.processInfo.systemUptime < deadline else { return changed ? next : nil }
    }
}

public func scrollToElement(
    _ selector: ElementSelector, direction: String, maxScrolls: Int, x: Double?, y: Double?,
    source: ElementSource = .ax, languages: [String] = ["zh-Hans", "en-US"],
) throws -> [String: Any] {
    try requirePointInput()
    guard (1 ... 100).contains(maxScrolls) else { throw IcliError.failed("max-scrolls must be 1–100") }
    let metrics = icli_screen_metrics()
    let horizontal = direction == "left" || direction == "right"
    var stroke = (horizontal ? metrics.width : metrics.height) * 0.45
    let endOfContent = { (scrolls: Int) in
        IcliError.commandFailed([
            "error": "not_found", "reason": "end_of_content", "scrolls": scrolls, "status": 1,
            "message": "reached the end of the content scrolling \(direction) without finding it; try the other direction",
        ])
    }
    var frames = FrameGate()
    defer { frames.close() }
    var scrolls = 0, pages = 0, rechecked = false
    var reading: ScreenReading?
    func pick(_ hits: [[String: Any]]) -> (element: [String: Any], count: Int)? {
        let best = selector.indexIsExplicit
            ? (hits.indices.contains(selector.index) ? [hits[selector.index]] : [])
            : bestMatches(hits, selector)
        return best.first.map { ($0, best.count) }
    }
    while true {
        let hits: [[String: Any]], used: ElementSource
        if source == .ax {
            let current = try reading ?? ScreenReading()
            reading = current
            (hits, used) = (current.elements.filter(selector.matches), .ax)
        } else {
            (hits, used) = try throughAppSwitch { try selectedElements(selector, source: source, languages: languages) }
        }
        if var found = pick(hits) {
            var revealed = false
            if used == .ax, let pid = try? throughAppSwitch(onScreenPID), let px = elementCoordinate(found.element["x"]),
               let py = elementCoordinate(found.element["y"])
            {
                // Found with its tap point clipped by the list's edge or a bar: a tap there would miss.
                let before = try reading?.signature ?? ScreenReading().signature
                frames.mark()
                let answer = try? decodeBridgeJSON(takeCString(icli_ax_reveal_json(
                    pid, found.element["label"] as? String ?? "", found.element["identifier"] as? String ?? "", px, py)), "AX reveal")
                if answer?["revealed"] as? Bool == true, let after = try readingAfterChange(from: before, frames: &frames),
                   let moved = pick(after.elements.filter(selector.matches))
                {
                    found = moved
                    revealed = true
                }
            }
            var result: [String: Any] = ["found": true, "element": found.element, "scrolls": scrolls, "matches": found.count]
            if scrolls > 0 { result["method"] = pages > 0 ? "accessibility" : "touch" }
            if revealed { result["revealed"] = true }
            if source != .ax { result["source"] = used.rawValue }
            return result
        }
        if scrolls == maxScrolls {
            throw IcliError.commandFailed([
                "error": "not_found", "reason": "max_scrolls", "scrolls": scrolls, "status": 1,
                "message": "scrolled \(direction) \(scrolls) times without finding it; raise --max-scrolls or try the other direction",
            ])
        }
        // The tree tells when a page has finished, also when the search reads text
        // from the screen: a tree read is 30 ms, recognizing the screen far longer.
        let before = reading?.signature ?? (try? ScreenReading())?.signature
        // The page action first: no touch, no momentum, and a page never skips content.
        frames.mark()
        let page = (try? throughAppSwitch(onScreenPID)).flatMap { pid in
            try? decodeBridgeJSON(takeCString(icli_ax_scroll_page_json(
                pid, x ?? metrics.width / 2, y ?? metrics.height / 2, direction, pages > 0)), "AX scroll")
        }
        if page?["moved"] as? Bool == true {
            let after = try before.flatMap { try readingAfterChange(from: $0, frames: &frames) }
            if source == .ax, let after {
                reading = after
                scrolls += 1
                pages += 1
                continue
            }
            if source != .ax {
                // Moved, by accessibility's word; where the tree shows nothing of it,
                // the screen going still says the page is done.
                if after == nil, !frames.waitStill(quiet: 0.15, limit: 2) { Thread.sleep(forTimeInterval: 0.35) }
                scrolls += 1
                pages += 1
                continue
            }
        } else if pages > 0 {
            // It has been scrolling this view, so no ancestor left means the end. The
            // tree has once been seen to lag a row behind there, so it is read again.
            if source == .ax, !rechecked {
                rechecked = true
                reading = try ScreenReading()
                continue
            }
            throw endOfContent(scrolls)
        }
        // Accessibility cannot scroll this view: a stroke, and the screen says whether it
        // moved. Three quarters of the view's size, where it is known, keeps the screens
        // overlapping so no row is skipped.
        if let extent = page?[horizontal ? "viewport_width" : "viewport_height"] as? Double, extent >= 40 {
            stroke = min(stroke, extent * 0.75)
        }
        reading = nil
        let settledBefore = try settledSignature(source: source, languages: languages)
        _ = try scrollBy(direction: direction, points: stroke, x: x, y: y)
        scrolls += 1
        if try settledSignature(source: source, languages: languages) == settledBefore { throw endOfContent(scrolls) }
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
    return try fillTappedField(element: tapped["element"] ?? [:], value: value, submit: submit)
}

/// The same, for a field at a point: taps there, empties the field and enters the text.
public func fillField(x: Double, y: Double, value: String?, submit: Bool) throws -> [String: Any] {
    _ = try tap(x: x, y: y)
    return try fillTappedField(element: ["x": x, "y": y], value: value, submit: submit)
}

private func fillTappedField(element: Any, value: String?, submit: Bool) throws -> [String: Any] {
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
    return ["filled": true, "element": element, "keyboard_seen": keyboard, "sent": value?.count ?? 0]
}

/// Runs after an action: waits until an element with `appear` is on screen, or
/// none with `gone` is. A wait that fails says the action itself ran.
public func expectAfter(_ action: [String: Any], appear: String?, gone: String?, timeout: Double) throws -> [String: Any] {
    guard let text = appear ?? gone else { return action }
    do {
        let waited = try waitForElement(ElementSelector(text: text), appear: appear != nil, timeout: timeout, interval: 0.1)
        var result = action
        result["expect"] = waited
        return result
    } catch {
        let reason = (error as? IcliError)?.message ?? error.localizedDescription
        throw IcliError.commandFailed([
            "error": "expect_failed", "status": 1, "action": action,
            "message": reason == "element wait timed out"
                ? "the action ran, but \(text) \(appear != nil ? "did not appear within" : "was still on screen after") \(timeout) s"
                : "the action ran, but waiting for \(text) failed: \(reason)",
        ])
    }
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
    // A tap that lands while the alert is still animating in is dropped, so
    // the alert closing is what confirms the answer. Only the same alert, its
    // button at the same point under the same title, gets a second tap: the
    // next alert an app opens in its place must not be answered for it.
    let label = alertText(hit["label"] as? String ?? "")
    let body = usesText ? [] : alertBody(elements, above: hit)
    func sameAlertShown() throws -> Bool {
        let now = usesText ? try alertTextElements() : try alertElements()
        let button = now.contains {
            alertText($0["label"] as? String ?? "") == label
                && abs((elementCoordinate($0["x"]) ?? -100) - x) < 3 && abs((elementCoordinate($0["y"]) ?? -100) - y) < 3
        }
        return button && body.isSubset(of: Set(now.compactMap { $0["label"] as? String }))
    }
    var attempts = 1
    var deadline = ProcessInfo.processInfo.systemUptime + 1
    while try sameAlertShown() {
        if ProcessInfo.processInfo.systemUptime >= deadline {
            guard attempts < 2, !body.isEmpty else {
                throw IcliError.commandFailed([
                    "error": "alert_open", "status": 1, "button": hit["label"] ?? "", "attempts": attempts, "source": source,
                    "message": "tapped \(hit["label"] as? String ?? "the button"), but the alert is still on screen",
                ])
            }
            _ = try tap(x: x, y: y)
            attempts += 1
            deadline = ProcessInfo.processInfo.systemUptime + 1
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return ["tapped": true, "closed": true, "attempts": attempts, "button": hit["label"] ?? "", "x": x, "y": y, "source": source]
}

/// The labels above a button that sit across its tap point: the alert's title
/// and message, which tell this alert from the next one.
private func alertBody(_ elements: [[String: Any]], above button: [String: Any]) -> Set<String> {
    guard let x = elementCoordinate(button["x"]),
          let top = (button["frame"] as? [String: Any]).flatMap({ elementCoordinate($0["y"]) })
    else { return [] }
    return Set(elements.compactMap { element -> String? in
        guard let frame = element["frame"] as? [String: Any],
              let minX = elementCoordinate(frame["x"]), let minY = elementCoordinate(frame["y"]),
              let width = elementCoordinate(frame["width"]), let height = elementCoordinate(frame["height"]),
              minY > statusBarBottom, minY + height <= top, minX <= x, x <= minX + width,
              let label = element["label"] as? String, !label.isEmpty
        else { return nil }
        return label
    })
}

/// Opens Settings at an app's own page (its permissions, notifications and
/// settings) and confirms Settings shows it: the app's name as the page's
/// navigation title. iOS 17 lists only apps with something to set there, and
/// opens Settings' main page for any other app, which is a failure here.
public func openAppSettings(_ bundleID: String, timeout: TimeInterval = 5) throws -> [String: Any] {
    guard timeout.isFinite, (0 ... 60).contains(timeout) else { throw IcliError.failed("timeout must be 0–60 seconds") }
    let name = appDisplayName(bundleID) ?? bundleID
    // prefs:root=<bundle id> opens a third-party app's page (measured on iOS 17.1.1).
    let url = "prefs:root=" + bundleID
    _ = try openURL(url)
    let start = ProcessInfo.processInfo.systemUptime
    var frames = FrameGate()
    defer { frames.close() }
    repeat {
        frames.mark()
        let checked = ProcessInfo.processInfo.systemUptime
        if frontmostApp()["bundle_id"] as? String == settingsBundleID,
           let elements = (try? uiElements(scope: .app))?["elements"] as? [[String: Any]],
           elements.contains(where: { element in
               (element["label"] as? String)?.compare(name, options: .caseInsensitive) == .orderedSame
                   && (elementCoordinate(element["y"]) ?? .infinity) < navigationTitleBottom
           })
        {
            return ["opened": true, "app": bundleID, "name": name, "url": url,
                    "waited_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1000), "trigger": frames.trigger]
        }
        let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
        guard frames.wait(limit: remaining, interval: 0.1, since: checked) else { break }
    } while ProcessInfo.processInfo.systemUptime - start <= timeout
    throw IcliError.commandFailed([
        "error": "no_settings_page", "status": 1, "app": bundleID, "name": name, "url": url,
        "message": "Settings shows no page for \(name); iOS lists only apps with settings, permissions or notifications",
    ])
}

private let settingsBundleID = "com.apple.Preferences"
/// A Settings page's navigation title centres at y 76 on an iPhone 15 Pro Max;
/// its first row starts below 110 (measured on iOS 17.1.1).
private let navigationTitleBottom = 110.0
