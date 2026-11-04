import Accelerate
import CoreVideo
import Foundation
import IcliLaunch
import IcliPrivate
import IcliSystem
import Metal
import UIKit
import Vision

public func takeScreenshot(
    path requestedPath: String? = nil,
    base64: Bool = false,
    nativeResolution: Bool = false,
) throws -> [String: Any] {
    icli_private_init()
    let path = requestedPath ?? (JailbreakRoot.current.scratchDirectory() + "/icli-\(UUID().uuidString).jpg")
    // A path icli chose itself is of no use to the caller until it is reported
    // back, so it is removed when the caller wanted base64 instead and when the
    // call fails after the capture. A path the caller named is left to them.
    var reported = false
    defer {
        if requestedPath == nil, !reported {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
    guard icli_screenshot_jpeg(path, 0.8, 800_000, nativeResolution) else {
        throw IcliError.failed("screenshot failed")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let image = UIImage(data: data)?.cgImage else { throw IcliError.failed("screenshot is not a valid image") }
    let metrics = icli_screen_metrics()
    var result: [String: Any] = ["bytes": data.count, "mime_type": "image/jpeg", "width": image.width,
                                 "height": image.height, "coordinate_scale": Double(image.width) / metrics.width]
    if base64 {
        result["data"] = data.base64EncodedString()
    }
    if !base64 || requestedPath != nil {
        result["path"] = path
        reported = true
    }
    return result
}

/// One screenshot's JPEG bytes, for a caller that wants them and no file.
public func screenshotJPEGData(nativeResolution: Bool = false) throws -> Data {
    icli_private_init()
    let path = JailbreakRoot.current.scratchDirectory() + "/icli-\(UUID().uuidString).jpg"
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard icli_screenshot_jpeg(path, 0.8, 800_000, nativeResolution) else {
        throw IcliError.failed("screenshot failed")
    }
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

/// tvOS has neither a touch screen nor a pointer: a touch or click at a point
/// reaches nothing there, so it is refused rather than reported as sent.
func requirePointInput() throws {
    #if os(tvOS)
    throw IcliError.unavailable(
        "tvOS has no touch screen or pointer; move focus with `input hid 12 66`…`69` (up, down, left, right) and select with `input hid 12 65`.",
    )
    #endif
}

public func tap(x: Double, y: Double) throws -> [String: Any] {
    try requirePointInput()
    try validatePoint(x, y)
    guard icli_hid_tap(x, y) else { throw IcliError.failed("hid tap unavailable") }
    return ["x": x, "y": y]
}

public func doubleTap(x: Double, y: Double, interval: Double = 0.1) throws -> [String: Any] {
    try requirePointInput()
    try validatePoint(x, y)
    try validateDuration(interval, name: "interval", maximum: 1)
    guard icli_hid_double_tap(x, y, interval) else { throw IcliError.failed("hid double-tap unavailable") }
    return ["x": x, "y": y]
}

public func longPress(x: Double, y: Double, seconds: Double) throws -> [String: Any] {
    try requirePointInput()
    try validatePoint(x, y)
    try validateDuration(seconds, name: "seconds")
    guard icli_hid_long_press(x, y, seconds) else { throw IcliError.failed("hid long-press unavailable") }
    return ["x": x, "y": y, "seconds": seconds]
}

public func swipe(
    x1: Double,
    y1: Double,
    x2: Double,
    y2: Double,
    seconds: Double,
    steps: Int = 20,
) throws -> [String: Any] {
    try requirePointInput()
    try validatePoint(x1, y1)
    try validatePoint(x2, y2)
    try validateDuration(seconds, name: "seconds")
    guard (1 ... 2000).contains(steps) else { throw IcliError.failed("steps must be 1–2000") }
    guard icli_hid_swipe(x1, y1, x2, y2, seconds, Int32(steps)) else { throw IcliError.failed("hid swipe unavailable") }
    return ["from": [x1, y1], "to": [x2, y2]]
}

public func pinch(
    x: Double,
    y: Double,
    from: Double,
    to: Double,
    angle: Double = 0,
    seconds: Double = 0.4,
    steps: Int = 20,
) throws -> [String: Any] {
    try requirePointInput()
    guard from > 0, to > 0, from.isFinite, to.isFinite else { throw IcliError.failed("from and to must be positive distances") }
    guard angle.isFinite else { throw IcliError.failed("angle must be finite") }
    let r = max(from, to) / 2, a = angle * .pi / 180
    try validatePoint(x - r * cos(a), y - r * sin(a))
    try validatePoint(x + r * cos(a), y + r * sin(a))
    try validateDuration(seconds, name: "seconds")
    guard (1 ... 2000).contains(steps) else { throw IcliError.failed("steps must be 1–2000") }
    guard icli_hid_pinch(x, y, from, to, angle, seconds, Int32(steps)) else { throw IcliError.failed("hid pinch unavailable") }
    return ["center": [x, y], "from": from, "to": to, "angle": angle]
}

public func drag(
    points: [(Double, Double)],
    seconds: Double,
    hold: Double = 0.5,
    steps: Int = 20,
) throws -> [String: Any] {
    try requirePointInput()
    guard (2 ... 1000).contains(points.count), (points.count - 1 ... 2000).contains(steps) else {
        throw IcliError.failed("drag needs 2–1000 points and steps >= segments, up to 2000")
    }
    for (x, y) in points {
        try validatePoint(x, y)
    }
    try validateDuration(seconds, name: "seconds")
    try validateDuration(hold, name: "hold", allowZero: true)
    var xs = points.map(\.0)
    var ys = points.map(\.1)
    let ok = xs.withUnsafeMutableBufferPointer { xb in
        ys.withUnsafeMutableBufferPointer { yb in
            icli_hid_drag(xb.baseAddress, yb.baseAddress, Int32(points.count), hold, seconds, Int32(steps))
        }
    }
    guard ok else { throw IcliError.failed("hid drag unavailable") }
    return ["points": points.count]
}

public func pressButton(_ name: String) throws -> [String: Any] {
    if ["volume-up", "volume-down", "mute"].contains(name) {
        return try decodeBridgeJSON(takeCString(icli_audio_button_json(name)), "audio button response")
    }
    if name == "wake" {
        guard icli_wake() else { throw IcliError.failed("wake failed") }
        #if os(tvOS)
        try dismissScreenSaver()
        #endif
        let lock = icli_lock_status()
        return ["button": name, "locked": lock.locked, "screen_off": lock.screen_off]
    }
    guard icli_hid_button(name) else { throw IcliError.failed("unknown or failed button: \(name)") }
    return ["button": name]
}

#if os(tvOS)
/// tvOS has no lock screen: what stands between a remote and the screen it
/// would work is the screen saver, which waking the display leaves in place.
/// PineBoard dismisses it on request, which presses nothing; a screen saver
/// still coming up ignores the request, and only then does this press Select
/// once, as on the Siri Remote. The request takes effect within half a
/// second, so Select is pressed only on a screen saver still showing, never on
/// what lies beneath one that is already going.
private func dismissScreenSaver() throws {
    func gone(within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while frontmostApp()["bundle_id"] as? String == "com.apple.IdleScreen" {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }
    if gone(within: 0) { return }
    if icli_deactivate_screen_saver(), gone(within: 1.5) { return }
    _ = try hidPress(page: 0x0C, usage: 0x41)
    guard gone(within: 5) else { throw IcliError.failed("wake failed: the screen saver stayed on screen") }
}
#endif

public func typeText(_ text: String, delayMS: Double = 30) throws -> [String: Any] {
    guard !text.isEmpty, text.utf8.count <= 64 * 1024, delayMS.isFinite, (0 ... 1000).contains(delayMS) else {
        throw IcliError.failed("text must contain 1–65536 bytes and delay-ms must be 0–1000")
    }
    for character in text {
        guard icli_hid_text(String(character)) else { throw IcliError.failed("Unicode HID input unavailable") }
        Thread.sleep(forTimeInterval: delayMS / 1000)
    }
    return ["sent": text.count, "method": "unicode_hid"]
}

public func pressKey(_ name: String) throws -> [String: Any] {
    let keys: [String: UInt16] = ["return": 0x28, "enter": 0x28, "delete": 0x2A, "backspace": 0x2A,
                                  "tab": 0x2B, "escape": 0x29, "space": 0x2C, "up": 0x52, "down": 0x51, "left": 0x50,
                                  "right": 0x4F, "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "pagedown": 0x4E]
    let parts = name.lowercased().split(separator: "+").map(String.init)
    let modifierKeys: [String: UInt16] = [
        "cmd": 0xE3, "command": 0xE3, "ctrl": 0xE0, "control": 0xE0, "shift": 0xE1, "alt": 0xE2, "option": 0xE2,
    ]
    var modifiers: [UInt16] = []
    for part in parts.dropLast() {
        guard let key = modifierKeys[part] else { throw IcliError.failed("unknown modifier: \(part)") }
        modifiers.append(key)
    }
    let key = parts.last ?? ""
    let letter = key.utf8.count == 1 ? key.utf8.first : nil
    let usage = keys[key] ?? letter.flatMap { (97 ... 122).contains($0) ? UInt16($0 - 97 + 4) : nil }
    guard let usage else { throw IcliError.failed("unknown key: \(name)") }
    defer { for modifier in modifiers.reversed() {
        _ = icli_hid_key(0x07, modifier, false)
    } }
    for modifier in modifiers {
        guard icli_hid_key(0x07, modifier, true) else { throw IcliError.failed("HID keyboard unavailable") }
    }
    guard icli_hid_key(0x07, usage, true) else { throw IcliError.failed("HID keyboard unavailable") }
    usleep(20000)
    guard icli_hid_key(0x07, usage, false) else { throw IcliError.failed("HID key release failed") }
    return ["key": name, "dispatched": true]
}

public func pasteText(_ text: String) throws -> [String: Any] {
    guard !text.isEmpty, text.utf8.count <= 64 * 1024 else {
        throw IcliError.failed("text must contain 1–65536 bytes")
    }
    guard icli_hid_text(text) else { throw IcliError.failed("Unicode HID input unavailable") }
    return ["sent": text.count, "method": "unicode_hid"]
}

public func openURL(_ url: String) throws -> [String: Any] {
    guard icli_open_url(url) else { throw IcliError.failed("open url failed") }
    return ["url": url]
}

/// Reads the screen's text. `region` limits it to part of the screen, which is
/// quicker; `fast` trades accuracy for speed and reads fewer languages.
public func recognizeScreen(
    languages: [String], minConfidence: Float, locating: String? = nil, region: ScreenRegion? = nil, fast: Bool = false,
) throws -> [String: Any] {
    guard !languages.isEmpty, minConfidence.isFinite, (0 ... 1).contains(minConfidence) else {
        throw IcliError.failed("provide languages and confidence between 0 and 1")
    }
    guard let image = icli_screen_cgimage(true) else { throw IcliError.failed("OCR screenshot failed") }
    return try recognizeImage(
        image, languages: languages, minConfidence: minConfidence, locating: locating, region: region, fast: fast,
    )
}

private func recognizeImage(
    _ fullImage: CGImage, languages: [String], minConfidence: Float, locating: String? = nil,
    region: ScreenRegion? = nil, fast: Bool = false,
) throws -> [String: Any] {
    let fullPoints = pointSizeMatching(image: fullImage)
    var cgImage = fullImage
    var origin = CGPoint.zero
    if let region {
        guard CGRect(origin: .zero, size: fullPoints).contains(region.rect) else {
            throw IcliError.failed("region is outside the screen")
        }
        let scale = CGFloat(fullImage.width) / fullPoints.width
        let crop = CGRect(x: region.rect.minX * scale, y: region.rect.minY * scale,
                          width: region.rect.width * scale, height: region.rect.height * scale).integral
        guard let cropped = fullImage.cropping(to: crop) else { throw IcliError.failed("region is outside the screen") }
        cgImage = cropped
        origin = region.rect.origin
    }
    // A process started over SSH or launchd has no GPU device: the kernel denies the GPU
    // user client to non-app processes, so MTLCreateSystemDefaultDevice() is nil, Vision's
    // IOSurface-backed pixel buffers (and any CoreImage GL context) fail or crash. On iOS 17+
    // Vision runs the request on the CPU from a plain (non-IOSurface) pixel buffer we fill with
    // vImage, avoiding both. Older systems without a GPU device stay unavailable.
    let haveGPU = MTLCreateSystemDefaultDevice() != nil
    let pointSize = region?.rect.size ?? fullPoints
    let downsampled = downsampledCGImage(cgImage, maxEdge: 1600)
    do {
        var blocks: [[String: Any]]
        if haveGPU {
            blocks = try visionBlocks(in: downsampled, languages: languages, minConfidence: minConfidence,
                                      pointSize: pointSize, locating: locating, fast: fast)
        } else if #available(iOS 17.0, *) {
            blocks = try visionBlocksCPU(in: downsampled, languages: languages, minConfidence: minConfidence,
                                         pointSize: pointSize, locating: locating, fast: fast)
        } else {
            throw IcliError.unavailable("System text recognition is unavailable on this device.")
        }
        if origin != .zero {
            blocks = blocks.map { block in
                var block = block
                for (key, offset) in [("x", origin.x), ("match_x", origin.x), ("y", origin.y), ("match_y", origin.y)] {
                    if let value = elementCoordinate(block[key]) { block[key] = value + Double(offset) }
                }
                return block
            }
        }
        var result: [String: Any] = ["blocks": blocks, "count": blocks.count, "engine": "vision"]
        if fast { result["level"] = "fast" }
        return result
    } catch let error as IcliError {
        throw error
    } catch {
        throw IcliError.unavailable("System text recognition is unavailable on this device.")
    }
}

/// Whose elements a query reads. `auto` is what can be reached now: the app on
/// screen, with anything SpringBoard shows over it (an alert, a banner, Control
/// Center, the app switcher) listed first. `app` and `system` read one side only;
/// `all` reads both, the status bar included.
public enum ElementScope: String {
    case auto, app, system, all
}

/// Everything SpringBoard lists while an app is in front sits in the status bar,
/// whose elements all centre above this line on the phones measured.
let statusBarBottom = 60.0

private func tagged(_ elements: [[String: Any]], scope: String) -> [[String: Any]] {
    elements.map { element in
        var element = element
        element["scope"] = scope
        return element
    }
}

func axElements(pid: Int32, maxElements: Int) throws -> [String: Any] {
    try decodeBridgeJSON(takeCString(icli_ax_elements_json(pid, Int32(maxElements))), "AX response")
}

public func uiElements(
    maxElements: Int = 250,
    visibleOnly: Bool = true,
    clickableOnly: Bool = false,
    limit: Int? = nil,
    scope: ElementScope = .auto,
) throws -> [String: Any] {
    guard (1 ... 2000).contains(maxElements), limit == nil || (limit! > 0 && limit! <= 2000) else {
        throw IcliError.failed("element limits must be between 1 and 2000")
    }
    var result: [String: Any]
    switch scope {
    case .auto:
        let front = try onScreenPID()
        result = try axElements(pid: front, maxElements: maxElements)
        // Over SpringBoard itself or a hidden app such as Spotlight there is nothing to add.
        var overlay = false
        if let shell = try? systemShellPID(), shell != front,
           let system = try? axElements(pid: shell, maxElements: maxElements)
        {
            let covering = (system["elements"] as? [[String: Any]] ?? []).filter {
                $0["visible"] as? Bool == true && (elementCoordinate($0["y"]) ?? 0) > statusBarBottom
            }
            if !covering.isEmpty {
                overlay = true
                result["elements"] = tagged(covering, scope: "system") + (result["elements"] as? [[String: Any]] ?? [])
            }
        }
        result["system_overlay"] = overlay
    case .app:
        result = try axElements(pid: onScreenPID(), maxElements: maxElements)
    case .system:
        result = try axElements(pid: systemShellPID(), maxElements: maxElements)
    case .all:
        let shell = try systemShellPID()
        result = try axElements(pid: shell, maxElements: maxElements)
        let front = try onScreenPID()
        if front != shell {
            let app = try axElements(pid: front, maxElements: maxElements)
            result["elements"] = tagged(result["elements"] as? [[String: Any]] ?? [], scope: "system")
                + (app["elements"] as? [[String: Any]] ?? [])
            if app["truncated"] as? Bool == true { result["truncated"] = true }
        }
    }
    var elements = result["elements"] as? [[String: Any]] ?? []
    if visibleOnly {
        elements = elements.filter { $0["visible"] as? Bool == true }
    }
    if clickableOnly {
        elements = elements.filter { $0["clickable"] as? Bool == true }
    }
    if let limit {
        elements = Array(elements.prefix(limit))
    }
    result["elements"] = elements
    result["count"] = elements.count
    return result
}

/// The screen's elements from the accessibility tree, from text recognition, or
/// from the tree and, when it lists nothing, from text recognition.
public func screenElements(
    source: ElementSource, languages: [String], maxElements: Int = 250, visibleOnly: Bool = true,
    clickableOnly: Bool = false, limit: Int? = nil, scope: ElementScope = .auto,
) throws -> [String: Any] {
    guard source == .ax || !clickableOnly else {
        throw IcliError.failed("text recognition does not know what can be tapped; --clickable-only needs --source ax")
    }
    if source != .ocr {
        let tree = try uiElements(
            maxElements: maxElements, visibleOnly: visibleOnly, clickableOnly: clickableOnly, limit: limit, scope: scope,
        )
        if source == .ax || !(tree["elements"] as? [[String: Any]] ?? []).isEmpty { return tree }
    }
    guard limit == nil || (limit! > 0 && limit! <= 2000) else {
        throw IcliError.failed("element limits must be between 1 and 2000")
    }
    let blocks = try recognizeScreen(languages: languages, minConfidence: 0.3)["blocks"] as? [[String: Any]] ?? []
    let elements = blocks.map { block -> [String: Any] in
        var element = block
        element["label"] = block["text"]
        element["visible"] = true
        return element
    }
    let shown = limit.map { Array(elements.prefix($0)) } ?? elements
    return ["elements": shown, "count": shown.count, "truncated": false, "source": "ocr"]
}

public func describeScreen() throws -> [String: Any] {
    let frontmost = frontmostApp()
    guard let original = icli_screen_cgimage(true) else { throw IcliError.failed("screen capture failed") }
    let image = UIImage(cgImage: original)
    let pointSize = pointSizeMatching(image: original)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let resized = UIGraphicsImageRenderer(size: pointSize, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: pointSize))
    }
    guard let jpeg = resized.jpegData(compressionQuality: 0.8) else {
        throw IcliError.failed("snapshot JPEG encoding failed")
    }
    var payload: [String: Any] = [
        "frontmost": frontmost,
        "screen": screenInfo(),
        "screenshot": [
            "data": jpeg.base64EncodedString(),
            "mime_type": "image/jpeg",
            "width": pointSize.width,
            "height": pointSize.height,
            "coordinate_scale": 1,
            "bytes": jpeg.count,
        ],
    ]
    do { payload["elements"] = try uiElements() }
    catch let error as IcliError { payload["elements"] = error.payload }
    catch { payload["elements"] = ["error": "failed", "message": error.localizedDescription] }
    do { payload["ocr"] = try recognizeImage(original, languages: ["zh-Hans", "en-US"], minConfidence: 0.3) }
    catch let error as IcliError { payload["ocr"] = error.payload }
    catch { payload["ocr"] = ["error": "failed", "message": error.localizedDescription] }
    let read = [payload["elements"], payload["ocr"]].compactMap { $0 as? [String: Any] }
    payload["prompt"] = promptKind(in: read.flatMap { screenText($0["elements"] ?? $0["blocks"]) }) as Any? ?? NSNull()
    let after = frontmostApp()
    payload["context_changed"] = frontmost["verified"] as? Bool != true
        || after["verified"] as? Bool != true
        || after["bundle_id"] as? String != frontmost["bundle_id"] as? String
    return payload
}

public func elementAt(x: Double, y: Double) throws -> [String: Any] {
    try validatePoint(x, y)
    return try decodeBridgeJSON(takeCString(icli_ax_element_at_json(onScreenPID(), x, y)), "AX response")
}

/// Turns the system-wide accessibility switches that element queries turned on
/// back off. The icli command does this when it exits; a long-running host
/// calls it when it stops reading the UI, since a host that is killed never
/// reaches its exit handlers. A later query turns them on again.
public func restoreAccessibilitySwitches() {
    icli_ax_restore_switches()
}

public struct ElementSelector {
    public let text: String?
    public let identifier: String?
    public let role: String?
    public let match: String
    public let index: Int
    /// A caller that names an index picks among the matches itself, so a tap
    /// skips the ranking and the refusal of ambiguous matches.
    public let indexIsExplicit: Bool

    public init(
        text: String?,
        identifier: String? = nil,
        role: String? = nil,
        match: String = "contains",
        index: Int? = nil,
    ) throws {
        indexIsExplicit = index != nil
        let index = index ?? 0
        guard text?.isEmpty == false || identifier?.isEmpty == false, ["contains", "exact"].contains(match),
              index >= 0
        else {
            throw IcliError.failed("provide text or identifier, match contains/exact, and a nonnegative index")
        }
        self.text = text; self.identifier = identifier; self.role = role; self.match = match; self.index = index
    }

    func matches(_ element: [String: Any]) -> Bool {
        if let role {
            if role == "control" {
                if element["clickable"] as? Bool != true {
                    return false
                }
            } else if role != "element", element["role"] as? String != role {
                return false
            }
        }
        if let identifier {
            return element["identifier"] as? String == identifier || element["label"] as? String == identifier
        }
        guard let text else { return false }
        return ["label", "identifier", "value"].contains { key in
            let value = element[key] as? String ?? ""
            return match == "exact"
                ? value.compare(text, options: .caseInsensitive) == .orderedSame
                : value.localizedCaseInsensitiveContains(text)
        }
    }
}

private func selectedElements(_ selector: ElementSelector) throws -> [[String: Any]] {
    let result = try uiElements(maxElements: 2000)
    guard result["truncated"] as? Bool != true else {
        throw IcliError.failed("AX query was truncated; narrow the screen before selecting an element")
    }
    return (result["elements"] as? [[String: Any]] ?? []).filter(selector.matches)
}

/// Where an element selector looks: the accessibility tree, on-screen text
/// recognition, or the tree first and then text recognition.
public enum ElementSource: String {
    case ax, ocr, any
}

/// OCR has only text to match, so an identifier or a role cannot apply to it.
private func ocrElements(_ selector: ElementSelector, languages: [String]) throws -> [[String: Any]] {
    guard let text = selector.text, !text.isEmpty, selector.identifier == nil, selector.role == nil else {
        throw IcliError.failed("OCR matches text only; provide text without --identifier or --role")
    }
    let blocks = try recognizeScreen(languages: languages, minConfidence: 0.3, locating: text)["blocks"]
        as? [[String: Any]] ?? []
    return blocks.compactMap { block in
        let line = block["text"] as? String ?? ""
        let hit = selector.match == "exact"
            ? line.compare(text, options: .caseInsensitive) == .orderedSame
            : line.localizedCaseInsensitiveContains(text)
        guard hit else { return nil }
        var element = block
        element["x"] = block["match_x"] ?? block["x"]
        element["y"] = block["match_y"] ?? block["y"]
        element["label"] = line
        element.removeValue(forKey: "match_x")
        element.removeValue(forKey: "match_y")
        return element
    }
}

/// The matches and the source that produced them. `any` falls through to OCR
/// only when the tree answered without a match; a failed tree query still stops.
func selectedElements(
    _ selector: ElementSelector, source: ElementSource, languages: [String],
) throws -> (hits: [[String: Any]], source: ElementSource) {
    switch source {
    case .ax:
        return (try selectedElements(selector), .ax)
    case .ocr:
        return (try ocrElements(selector, languages: languages), .ocr)
    case .any:
        let tree = try selectedElements(selector)
        if tree.indices.contains(selector.index) { return (tree, .ax) }
        return (try ocrElements(selector, languages: languages), .ocr)
    }
}

/// AX points are Double, OCR points CGFloat; `as? Double` rejects a CGFloat.
func elementCoordinate(_ value: Any?) -> Double? {
    switch value {
    case let value as Double: value
    case let value as CGFloat: Double(value)
    default: nil
    }
}

/// The matches a tap could mean: an exact match beats a partial one, then an
/// enabled element, then one that can be tapped. An element whose tap point lies
/// inside a better one is the same control described twice, so it does not count.
func bestMatches(_ hits: [[String: Any]], _ selector: ElementSelector) -> [[String: Any]] {
    func isExact(_ element: [String: Any]) -> Bool {
        guard selector.identifier == nil, let text = selector.text else { return true }
        return ["label", "identifier", "value"].contains {
            (element[$0] as? String ?? "").compare(text, options: .caseInsensitive) == .orderedSame
        }
    }
    func rank(_ element: [String: Any]) -> [Int] {
        // OCR text has no enabled or clickable state, so only exactness ranks it.
        [isExact(element) ? 0 : 1, element["scope"] as? String == "system" ? 0 : 1,
         element["enabled"] as? Bool == false ? 1 : 0, element["clickable"] as? Bool == false ? 1 : 0]
    }
    guard let best = hits.map(rank).min(by: { $0.lexicographicallyPrecedes($1) }) else { return [] }
    let tied = hits.filter { rank($0) == best }.enumerated().sorted { a, b in
        let lengths = [a.element, b.element].map { ($0["label"] as? String ?? "").count }
        return lengths[0] != lengths[1] ? lengths[0] < lengths[1] : a.offset < b.offset
    }.map(\.element)
    var kept: [[String: Any]] = []
    for element in tied {
        let nested = kept.contains { outer in
            guard let frame = outer["frame"] as? [String: Any],
                  let left = elementCoordinate(frame["x"]), let top = elementCoordinate(frame["y"]),
                  let width = elementCoordinate(frame["width"]), let height = elementCoordinate(frame["height"]),
                  let x = elementCoordinate(element["x"]), let y = elementCoordinate(element["y"])
            else { return false }
            return x >= left - 1 && x <= left + width + 1 && y >= top - 1 && y <= top + height + 1
        }
        if !nested { kept.append(element) }
    }
    return kept
}

func ambiguousMatches(_ matches: [[String: Any]]) -> IcliError {
    .commandFailed([
        "error": "ambiguous",
        "message": "\(matches.count) elements match equally well, so nothing was tapped; "
            + "use more of the text, --match exact, --identifier, --role or --index",
        "matches": matches.map { element in
            element.filter { ["label", "identifier", "value", "role", "x", "y", "scope"].contains($0.key) }
        },
        "status": 1,
    ])
}

public func tapElement(
    _ selector: ElementSelector,
    source: ElementSource = .ax,
    languages: [String] = ["zh-Hans", "en-US"],
) throws -> [String: Any] {
    try requirePointInput()
    let (hits, used) = try selectedElements(selector, source: source, languages: languages)
    let hit: [String: Any]
    if selector.indexIsExplicit {
        guard hits.indices.contains(selector.index) else { throw IcliError.failed("element not found") }
        hit = hits[selector.index]
    } else {
        let best = bestMatches(hits, selector)
        guard let first = best.first else { throw IcliError.failed("element not found") }
        guard best.count == 1 else { throw ambiguousMatches(best) }
        hit = first
    }
    guard let x = elementCoordinate(hit["x"]), let y = elementCoordinate(hit["y"]) else {
        throw IcliError.failed("element has no tap point")
    }
    _ = try tap(x: x, y: y)
    var result: [String: Any] = ["tapped": true, "element": hit]
    if source != .ax { result["source"] = used.rawValue }
    return result
}

public func waitForElement(
    _ selector: ElementSelector,
    appear: Bool,
    timeout: TimeInterval,
    interval: TimeInterval = 0.1,
    source: ElementSource = .ax,
    languages: [String] = ["zh-Hans", "en-US"],
) throws -> [String: Any] {
    guard timeout.isFinite, (0 ... 60).contains(timeout), interval.isFinite, (0.1 ... 5).contains(interval) else {
        throw IcliError.failed("timeout must be 0–60 seconds and interval 0.1–5 seconds")
    }
    let start = ProcessInfo.processInfo.systemUptime
    // An element can only appear or go once the screen draws a new frame, so
    // after each miss the wait sleeps until one is shown.
    var frames = FrameGate()
    defer { frames.close() }
    repeat {
        frames.mark()
        let checked = ProcessInfo.processInfo.systemUptime
        let (hits, used) = try selectedElements(selector, source: source, languages: languages)
        let present = hits.indices.contains(selector.index)
        if present == appear {
            var result: [String: Any] = [
                "found": present,
                "disappeared": !present,
                "waited_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1000),
                "element": present ? hits[selector.index] : [:],
                "trigger": frames.trigger,
            ]
            if source != .ax { result["source"] = used.rawValue }
            return result
        }
        let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
        guard frames.wait(limit: remaining, interval: interval, since: checked) else { break }
    } while ProcessInfo.processInfo.systemUptime - start <= timeout
    throw IcliError.failed("element wait timed out")
}

func validatePoint(_ x: Double, _ y: Double) throws {
    let metrics = icli_screen_metrics()
    guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < metrics.width, y < metrics.height else {
        throw IcliError.failed("coordinates must be finite points inside the screen")
    }
}

private func textRecognitionRequest(languages: [String], fast: Bool) -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = fast ? .fast : .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = languages
    return request
}

/// With `locating`, a block whose line contains that text also carries
/// `match_x`/`match_y`: the centre of the text itself rather than of the line.
private func textBlocks(from request: VNRecognizeTextRequest, minConfidence: Float,
                        pointSize: CGSize, locating: String? = nil) -> [[String: Any]] {
    return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= minConfidence else {
            return nil
        }
        let box = observation.boundingBox
        var block: [String: Any] = [
            "text": candidate.string, "confidence": candidate.confidence,
            "x": box.midX * pointSize.width, "y": (1 - box.midY) * pointSize.height,
            "width": box.width * pointSize.width, "height": box.height * pointSize.height,
        ]
        if let locating, let range = candidate.string.range(of: locating, options: .caseInsensitive),
           let matched = (try? candidate.boundingBox(for: range))?.boundingBox
        {
            block["match_x"] = matched.midX * pointSize.width
            block["match_y"] = (1 - matched.midY) * pointSize.height
        }
        return block
    }
}

private func visionBlocks(
    in image: CGImage,
    languages: [String],
    minConfidence: Float,
    pointSize: CGSize,
    locating: String? = nil,
    fast: Bool,
) throws -> [[String: Any]] {
    let request = textRecognitionRequest(languages: languages, fast: fast)
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return textBlocks(from: request, minConfidence: minConfidence, pointSize: pointSize, locating: locating)
}

// GPU-free OCR: Vision on the CPU over a plain (non-IOSurface) 420f buffer filled with vImage,
// so nothing needs the GPU user client the kernel withholds from non-app processes.
@available(iOS 17.0, *)
private func visionBlocksCPU(
    in image: CGImage,
    languages: [String],
    minConfidence: Float,
    pointSize: CGSize,
    locating: String? = nil,
    fast: Bool,
) throws -> [[String: Any]] {
    guard let buffer = cpuPixelBuffer420f(from: image) else {
        throw IcliError.unavailable("System text recognition is unavailable on this device.")
    }
    let request = textRecognitionRequest(languages: languages, fast: fast)
    for (stage, devices) in try request.supportedComputeStageDevices {
        if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
            request.setComputeDevice(cpu, for: stage)
        }
    }
    try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
    return textBlocks(from: request, minConfidence: minConfidence, pointSize: pointSize, locating: locating)
}

// A malloc-backed 420f CVPixelBuffer (IOSurface-backed ones need the GPU and fail here), filled
// from the CGImage with vImage on the CPU. Vision accepts it without allocating its own buffer.
private func cpuPixelBuffer420f(from image: CGImage) -> CVPixelBuffer? {
    let width = image.width, height = image.height
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              [:] as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
          let buffer = pixelBuffer else { return nil }

    var argb = vImage_Buffer()
    guard vImageBuffer_Init(&argb, vImagePixelCount(height), vImagePixelCount(width), 32,
                            vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
    defer { free(argb.data) }
    guard let context = CGContext(data: argb.data, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: argb.rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    var yp = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                           height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, 0)),
                           width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, 0)),
                           rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
    var cbcr = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
                             height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, 1)),
                             width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, 1)),
                             rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
    var info = vImage_ARGBToYpCbCr()
    var range = vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255,
                                        CbCrRangeMax: 255, YpMax: 255, YpMin: 0,
                                        CbCrMax: 255, CbCrMin: 0)
    guard vImageConvert_ARGBToYpCbCr_GenerateConversion(
        kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &info,
        kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    else { return nil }
    let permute: [UInt8] = [0, 1, 2, 3]
    guard vImageConvert_ARGB8888To420Yp8_CbCr8(&argb, &yp, &cbcr, &info, permute,
                                               vImage_Flags(kvImageNoFlags)) == kvImageNoError
    else { return nil }
    return buffer
}

private func downsampledCGImage(_ src: CGImage, maxEdge: CGFloat) -> CGImage {
    let width = src.width
    let height = src.height
    let longEdge = max(width, height)
    if CGFloat(longEdge) <= maxEdge {
        return src
    }
    let scale = maxEdge / CGFloat(longEdge)
    let newWidth = max(Int(CGFloat(width) * scale), 1)
    let newHeight = max(Int(CGFloat(height) * scale), 1)
    UIGraphicsBeginImageContextWithOptions(CGSize(width: newWidth, height: newHeight), true, 1)
    UIImage(cgImage: src, scale: 1, orientation: .up).draw(in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    let out = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
    UIGraphicsEndImageContext()
    return out ?? src
}

private func pointSizeMatching(image: CGImage) -> CGSize {
    let metrics = icli_screen_metrics()
    let imageIsLandscape = image.width > image.height
    let screenIsLandscape = metrics.width > metrics.height
    if imageIsLandscape == screenIsLandscape {
        return CGSize(width: metrics.width, height: metrics.height)
    }
    return CGSize(width: metrics.height, height: metrics.width)
}

func validateDuration(_ value: Double, name: String, maximum: Double = 60, allowZero: Bool = false) throws {
    guard value.isFinite, value <= maximum, allowZero ? value >= 0 : value > 0 else {
        throw IcliError.failed("\(name) must be \(allowZero ? "nonnegative" : "positive") and at most \(maximum) seconds")
    }
}
