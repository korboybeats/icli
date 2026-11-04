import Foundation
import IcliPrivate
import IcliSystem

private func amfiDeveloperMode(arm: Bool) throws -> [String: Any] {
    guard let raw = takeCString(icli_amfi_developer_mode_json(arm)),
          let reply = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    else {
        throw IcliError.unavailable("amfid sent an unreadable Developer Mode reply.")
    }
    if let error = reply["error"] as? String {
        throw IcliError.unavailable(error)
    }
    guard reply["success"] as? Bool == true else {
        let privilege = geteuid() == 0 ? "" : " Try again as root."
        throw IcliError.unavailable("amfid refused the Developer Mode request.\(privilege)")
    }
    return reply
}

/// Developer Mode as amfid reports it. `enabled` is the current state,
/// `armed` means it turns on after the next restart once the user confirms,
/// and `writable` is whether this device lets the state change at all.
/// Before iOS 16 there is no Developer Mode and nothing to ask amfid: the
/// developer features it gates are always allowed, so it reads as enabled.
public func developerModeStatus() throws -> [String: Any] {
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 16 {
        return ["enabled": true, "armed": false, "writable": false]
    }
    let reply = try amfiDeveloperMode(arm: false)
    return [
        "enabled": reply["status"] as? Bool ?? false,
        "armed": reply["armed"] as? Bool ?? false,
        "writable": reply["writable"] as? Bool ?? false,
    ]
}

/// Arms Developer Mode when it is off: it turns on after the next restart,
/// once the user confirms the prompt. Does nothing when it is already on.
public func enableDeveloperMode() throws -> [String: Any] {
    var status = try developerModeStatus()
    if status["enabled"] as? Bool == true || status["armed"] as? Bool == true {
        status["already_enabled"] = status["enabled"]
        status["restart_required"] = status["enabled"] as? Bool != true
        return status
    }
    guard status["writable"] as? Bool == true else {
        throw IcliError.unavailable("This device does not allow Developer Mode to be changed.")
    }
    _ = try amfiDeveloperMode(arm: true)
    var armed = try developerModeStatus()
    guard armed["armed"] as? Bool == true else {
        throw IcliError.unavailable("amfid accepted the request, but Developer Mode is not armed.")
    }
    armed["already_enabled"] = false
    armed["restart_required"] = true
    return armed
}

/// Whether Low Power Mode is on, as every app sees it through NSProcessInfo.
/// Changes go through powerd, like the Control Center toggle.
public func lowPowerMode() throws -> [String: Any] {
    guard icli_low_power_mode_get() >= 0 else {
        throw IcliError.unavailable("powerd's Low Power Mode service is unavailable on this device.")
    }
    return ["enabled": ProcessInfo.processInfo.isLowPowerModeEnabled, "method": "powerd"]
}

/// Turns Low Power Mode on or off through powerd and confirms the change
/// through NSProcessInfo.
public func setLowPowerMode(_ enabled: Bool) throws -> [String: Any] {
    let before = try lowPowerMode()["enabled"] as? Bool ?? false
    switch icli_low_power_mode_set(enabled) {
    case 0:
        break
    case -1:
        throw IcliError.unavailable("powerd's Low Power Mode setter is unavailable on this device.")
    case -2:
        throw IcliError.unavailable("powerd did not answer the Low Power Mode request within 3 seconds.")
    default:
        throw IcliError.unavailable("powerd refused the Low Power Mode change. The process needs the com.apple.powerd.lowpowermode.allow entitlement.")
    }
    let deadline = Date().addingTimeInterval(2)
    while ProcessInfo.processInfo.isLowPowerModeEnabled != enabled || icli_low_power_mode_get() != (enabled ? 1 : 0) {
        guard Date() < deadline else {
            throw IcliError.unavailable("The device did not apply the Low Power Mode change.")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return ["enabled": enabled, "changed": before != enabled, "method": "powerd"]
}

/// Light or dark mode as SpringBoard holds it.
public func appearance() throws -> [String: Any] {
    switch icli_appearance_get() {
    case 1: return ["appearance": "light"]
    case 2: return ["appearance": "dark"]
    default: throw IcliError.unavailable("This device's interface style service is unavailable.")
    }
}

public func setAppearance(_ value: String) throws -> [String: Any] {
    let modes = ["light": Int32(1), "dark": Int32(2)]
    guard let mode = modes[value] else { throw IcliError.failed("appearance must be light or dark") }
    let before = try appearance()["appearance"] as? String
    guard icli_appearance_set(mode) else {
        throw IcliError.unavailable("This device's interface style service is unavailable.")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while icli_appearance_get() != mode {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw IcliError.failed("the appearance stayed \(before ?? "unknown")")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return ["appearance": value, "changed": before != value]
}

private let textSizes = [
    "xs": "UICTContentSizeCategoryXS", "s": "UICTContentSizeCategoryS", "m": "UICTContentSizeCategoryM",
    "l": "UICTContentSizeCategoryL", "xl": "UICTContentSizeCategoryXL", "xxl": "UICTContentSizeCategoryXXL",
    "xxxl": "UICTContentSizeCategoryXXXL", "ax1": "UICTContentSizeCategoryAccessibilityM",
    "ax2": "UICTContentSizeCategoryAccessibilityL", "ax3": "UICTContentSizeCategoryAccessibilityXL",
    "ax4": "UICTContentSizeCategoryAccessibilityXXL", "ax5": "UICTContentSizeCategoryAccessibilityXXXL",
]

public func accessibilitySettings() throws -> [String: Any] {
    var settings = try decodeBridgeJSON(takeCString(icli_accessibility_json()), "accessibility settings")
    if let category = settings["text_size"] as? String {
        settings["text_size"] = textSizes.first { $0.value == category }?.key ?? category
    }
    return settings
}

public func setAccessibilitySettings(
    textSize: String?, reduceMotion: Bool?, increaseContrast: Bool?, reduceTransparency: Bool?,
) throws -> [String: Any] {
    guard textSize != nil || reduceMotion != nil || increaseContrast != nil || reduceTransparency != nil else {
        throw IcliError.failed("give --text-size, --reduce-motion, --increase-contrast or --reduce-transparency")
    }
    var category: String?
    if let textSize {
        guard let name = textSizes[textSize] else {
            throw IcliError.failed("text size must be xs, s, m, l, xl, xxl, xxxl or ax1–ax5")
        }
        category = name
    }
    let unavailable = "This setting is unavailable on this device."
    if let category, !icli_accessibility_set_text_size(category) { throw IcliError.unavailable(unavailable) }
    for (name, value) in [("reduce_motion", reduceMotion), ("increase_contrast", increaseContrast),
                          ("reduce_transparency", reduceTransparency)]
    {
        if let value, !icli_accessibility_set_flag(name, value) { throw IcliError.unavailable(unavailable) }
    }
    let flags = ["reduce_motion": reduceMotion, "increase_contrast": increaseContrast, "reduce_transparency": reduceTransparency]
        .compactMapValues { $0 }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while true {
        let now = try accessibilitySettings()
        var stale = flags.filter { now[$0.key] as? Bool != $0.value }.map(\.key)
        if let textSize, now["text_size"] as? String != textSize { stale.append("text_size") }
        if stale.isEmpty { return now }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw IcliError.failed("these settings did not change: \(stale.sorted().joined(separator: ", "))")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}
