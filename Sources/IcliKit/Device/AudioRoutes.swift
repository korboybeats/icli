import Foundation
import IcliPrivate
import IcliSystem

private func audioRouteResult(_ raw: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
    guard let text = takeCString(raw),
          let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { throw IcliError.failed("invalid audio-output response") }
    if result["error"] != nil { throw IcliError.commandFailed(result) }
    return result
}

/// Available Audio/Video outputs, with exact native UIDs and selected flags.
public func controlCenterAudioList() throws -> [String: Any] {
    try audioRouteResult(icli_cc_audio_list_json())
}

/// Selects a dynamically discovered route and waits for native confirmation.
/// Does not change volume, activate playback or change Bluetooth settings.
public func controlCenterAudioSelect(_ uid: String, timeout: Double = 8) throws -> [String: Any] {
    guard !uid.utf8.contains(0) else { throw IcliError.failed("route UID must contain no NUL bytes") }
    return try audioRouteResult(icli_cc_audio_select_json(uid, timeout))
}
