import Foundation

/// The one-line-per-element text `--compact` prints for `ui tree`, `ui at`,
/// `ui wait`, `ui wait-gone` and `screen ocr`.
///
/// The first line holds the result's own scalar fields as `key=value`: count,
/// truncated, system_overlay and source first, then the rest sorted. Then one
/// line per element (`elements`, `element`) or text block (`blocks`):
///
///     [role] ["label"] x,y WxH [id="…"] [value=…] [conf=0.98] [match=x,y] [scope=…] [clickable] [disabled] [offscreen]
///
/// x,y is the point a tap goes to (an element's activation point, which can
/// sit off its frame's centre), WxH the frame's size, all in whole points.
/// Labels, identifiers, string values and any other string that is not one
/// plain word are JSON string literals, so spaces, quotes and newlines stay
/// unambiguous. Empty fields and the defaults (enabled, visible) are left out.
public func compactText(_ dict: [String: Any]) -> String {
    let leading = ["count", "truncated", "system_overlay", "source"]
    let listed: Set = ["elements", "blocks", "element"]
    let keys = leading.filter { dict[$0] != nil }
        + dict.keys.filter { !leading.contains($0) && !listed.contains($0) }.sorted()
    var header: [String] = []
    for key in keys {
        let value = dict[key]!
        if let element = value as? [String: Any], key != "element" {
            header.append("\(key)=\(inlineJSON(element))")
        } else {
            header.append("\(key)=\(compactScalar(value))")
        }
    }
    var lines = [header.joined(separator: " ")]
    for key in ["element", "elements", "blocks"] {
        if let element = dict[key] as? [String: Any] {
            if !element.isEmpty { lines.append(compactElement(element)) }
        } else if let rows = dict[key] as? [[String: Any]] {
            // With --hierarchy, one leading space per level below the shallowest element.
            let depths = rows.compactMap { ($0["depth"] as? NSNumber)?.intValue }
            let shallowest = depths.min() ?? 0
            lines += rows.map { row in
                let indent = (row["depth"] as? NSNumber).map { max($0.intValue - shallowest, 0) } ?? 0
                return String(repeating: " ", count: indent) + compactElement(row)
            }
        } else if let other = dict[key] {
            lines[0] += (lines[0].isEmpty ? "" : " ") + "\(key)=\(inlineJSON(other))"
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

private func compactElement(_ element: [String: Any]) -> String {
    var parts: [String] = []
    if let role = element["role"] as? String, !role.isEmpty { parts.append(quotedIfNeeded(role)) }
    // OCR blocks carry text; OCR elements carry the same text as their label.
    if let label = (element["label"] ?? element["text"]) as? String, !label.isEmpty {
        parts.append(quoted(label))
    }
    parts.append("\(whole(element["x"])),\(whole(element["y"]))")
    let frame = element["frame"] as? [String: Any] ?? element
    parts.append("\(whole(frame["width"]))x\(whole(frame["height"]))")
    if let identifier = element["identifier"] as? String, !identifier.isEmpty {
        parts.append("id=" + quoted(identifier))
    }
    if let value = element["value"] as? String {
        if !value.isEmpty { parts.append("value=" + quoted(value)) }
    } else if let value = element["value"], !(value is NSNull) {
        parts.append("value=" + compactScalar(value))
    }
    if let confidence = (element["confidence"] as? NSNumber)?.doubleValue {
        parts.append(String(format: "conf=%.2f", confidence))
    }
    if element["match_x"] != nil || element["match_y"] != nil {
        parts.append("match=\(whole(element["match_x"])),\(whole(element["match_y"]))")
    }
    if let scope = element["scope"] as? String { parts.append("scope=" + quotedIfNeeded(scope)) }
    if element["clickable"] as? Bool == true { parts.append("clickable") }
    if element["enabled"] as? Bool == false { parts.append("disabled") }
    if element["visible"] as? Bool == false { parts.append("offscreen") }
    let handled: Set = [
        "role", "label", "text", "x", "y", "frame", "width", "height", "identifier", "value", "confidence",
        "match_x", "match_y", "scope", "clickable", "enabled", "visible", "depth",
        // The role and the enabled flag are read from the traits; the raw bits add nothing to read.
        "traits",
    ]
    for key in element.keys.filter({ !handled.contains($0) }).sorted() {
        parts.append("\(key)=\(compactScalar(element[key]!))")
    }
    return parts.joined(separator: " ")
}

private func whole(_ value: Any?) -> String {
    guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return "?" }
    return String(Int(number.rounded()))
}

private func compactScalar(_ value: Any) -> String {
    if let string = value as? String { return quotedIfNeeded(string) }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        let double = number.doubleValue
        guard double.isFinite else { return "null" }
        if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
        return String(format: "%.2f", double)
    }
    if value is NSNull { return "null" }
    return inlineJSON(value)
}

private func inlineJSON(_ value: Any) -> String {
    let safe = jsonSafe(value)
    guard JSONSerialization.isValidJSONObject(safe) || safe is String || safe is NSNumber,
          let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .fragmentsAllowed]),
          let text = String(data: data, encoding: .utf8)
    else { return "null" }
    return text
}

/// A bare word stays bare; anything else becomes a JSON string literal.
private func quotedIfNeeded(_ text: String) -> String {
    let plain = !text.isEmpty && text.unicodeScalars.allSatisfy {
        $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.:/+-".unicodeScalars.contains($0))
    }
    return plain ? text : quoted(text)
}

/// A JSON string literal: `"` and `\` escaped, control characters as escapes.
private func quoted(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7F || (0x2028 ... 0x2029).contains(scalar.value) {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}
