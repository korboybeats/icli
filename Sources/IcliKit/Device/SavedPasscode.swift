import Darwin
import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
import Security

private let savedPasscodeGroup = "com.icli.unlock"
private let savedPasscodeService = "com.icli.device-passcode"

private func savedPasscodeQuery() -> [String: Any] {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
     kSecAttrAccessGroup as String: savedPasscodeGroup,
     kSecAttrService as String: savedPasscodeService,
     kSecAttrAccount as String: "full-unlock",
     kSecAttrSynchronizable as String: false]
    // tvOS has no LocalAuthentication; its Keychain never prompts here.
    #if canImport(LocalAuthentication)
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    #endif
    return query
}

private func requireSavedPasscodeRoot() throws {
    guard geteuid() == 0 else {
        throw IcliError.failed("saved-passcode unlock requires a root terminal (or sudo icli unlock)")
    }
}

private func wipeSavedPasscode(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes {
        if let base = $0.baseAddress { memset_s(base, $0.count, 0, $0.count) }
    }
    bytes.removeAll(keepingCapacity: false)
}

private func savedPasscodeError(_ status: OSStatus) -> IcliError {
    if status == errSecItemNotFound {
        return .failed("no saved phone passcode; provision it once with icli-unlock --provision-phone from Windows/WSL")
    }
    if status == errSecInteractionNotAllowed {
        return .failed("saved passcode unavailable: unlock the phone manually once after a restart")
    }
    return .failed("saved-passcode Keychain operation failed (status \(status))")
}

/// Explicit one-time provisioning. Uses a separate, nonsynchronizing,
/// ThisDeviceOnly Keychain item; no file or command argument contains the code.
public func saveDevicePasscode(_ passcode: inout [UInt8]) throws -> [String: Any] {
    defer { wipeSavedPasscode(&passcode) }
    try requireSavedPasscodeRoot()
    guard (1 ... 128).contains(passcode.count), !passcode.contains(where: { [0, 10, 13].contains($0) }) else {
        throw IcliError.failed("the saved passcode must be 1–128 bytes without NUL or newline")
    }
    let status: OSStatus = passcode.withUnsafeBufferPointer { buffer in
        // The CFData wrapper borrows our owned input bytes. Security can
        // make its own copies; those are outside this caller's wiping control.
        guard let value = CFDataCreateWithBytesNoCopy(nil, buffer.baseAddress!, buffer.count, kCFAllocatorNull) else {
            return errSecAllocate
        }
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = savedPasscodeQuery()
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard update == errSecItemNotFound else { return update }
        var item = query.merging(attributes) { _, new in new }
        // This key controls queries; it is not an item attribute for SecItemAdd.
        item.removeValue(forKey: kSecUseAuthenticationContext as String)
        return SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw savedPasscodeError(status) }
    return ["saved": true, "storage": "device_keychain", "accessible": "after_first_unlock_this_device_only"]
}

/// No stdin or terminal reads. Missing/inaccessible storage fails without an
/// unlock attempt. The existing policy, ledger and full-unlock engine run once.
public func unlockWithSavedPasscode(limit: Int = defaultPasscodeFailureLimit,
                                    checkOnly: Bool = false) throws -> [String: Any] {
    try requireSavedPasscodeRoot()
    var query = savedPasscodeQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { throw savedPasscodeError(status) }
    guard let data = result as? Data else { throw IcliError.failed("saved passcode has an invalid Keychain format") }
    var passcode = [UInt8](data)
    defer { wipeSavedPasscode(&passcode) }
    var answer = try unlockDevice(passcode: &passcode, limit: limit, checkOnly: checkOnly, dismissLockScreen: true)
    answer["passcode_source"] = "device_keychain"
    return answer
}

/// Removes only the saved credential, never the rejected-passcode ledger.
public func removeSavedDevicePasscode() throws -> [String: Any] {
    try requireSavedPasscodeRoot()
    let status = SecItemDelete(savedPasscodeQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw savedPasscodeError(status) }
    return ["removed": status == errSecSuccess, "storage": "device_keychain"]
}
