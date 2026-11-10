import Darwin
import Foundation
import LocalAuthentication
import Security

enum IcliError: Error { case failed(String) }
public let defaultPasscodeFailureLimit = 3
var fakeUID: uid_t = 0
func geteuid() -> uid_t { fakeUID }
var item: [String: Any]?
var readStatus: OSStatus = errSecSuccess
var writeStatus: OSStatus = errSecSuccess
var unlockCalls = 0, reads = 0, updates = 0, adds = 0, deletes = 0
var checked = false, dismissed = false, suppliedLimit = 0
var unlockThrows = false
let fixture = Array("synthetic-fixture-only".utf8)

func assertQuery(_ query: CFDictionary) -> [String: Any] {
    let q = query as! [String: Any]
    precondition(q[kSecAttrAccessGroup as String] as? String == "com.korboy.icli.unlock")
    precondition(q[kSecAttrService as String] as? String == "com.korboy.icli.device-passcode")
    precondition(q[kSecAttrAccount as String] as? String == "full-unlock")
    precondition(q[kSecAttrSynchronizable as String] as? Bool == false)
    return q
}

func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let q = assertQuery(query); reads += 1
    precondition((q[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
    if readStatus != errSecSuccess { return readStatus }
    guard let item else { return errSecItemNotFound }
    result?.pointee = item[kSecValueData as String] as CFTypeRef?
    return errSecSuccess
}

func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    _ = assertQuery(query); updates += 1
    if writeStatus != errSecSuccess { return writeStatus }
    guard item != nil else { return errSecItemNotFound }
    let attrs = attributes as! [String: Any]
    item!.merge(attrs) { _, new in new }
    // Model the Keychain's own storage copy before the input is wiped.
    item![kSecValueData as String] = Data(attrs[kSecValueData as String] as! Data)
    return errSecSuccess
}

func SecItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let q = assertQuery(query); adds += 1
    precondition(q[kSecUseAuthenticationContext as String] == nil)
    if writeStatus != errSecSuccess { return writeStatus }
    item = q
    item![kSecValueData as String] = Data(q[kSecValueData as String] as! Data)
    return errSecSuccess
}

func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    _ = assertQuery(query); deletes += 1
    guard item != nil else { return errSecItemNotFound }
    item = nil
    return errSecSuccess
}

func unlockDevice(passcode: inout [UInt8], limit: Int, checkOnly: Bool, dismissLockScreen: Bool) throws -> [String: Any] {
    precondition(passcode == fixture)
    unlockCalls += 1; checked = checkOnly; dismissed = dismissLockScreen; suppliedLimit = limit
    if unlockThrows { throw IcliError.failed("synthetic engine failure") }
    passcode.removeAll()
    return ["status": 0, "attempted": !checkOnly]
}

func reset() {
    fakeUID = 0; item = nil; readStatus = errSecSuccess; writeStatus = errSecSuccess
    unlockCalls = 0; reads = 0; updates = 0; adds = 0; deletes = 0; unlockThrows = false
}
func expectError(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("expected error") } catch {}
}
var count = 0
func test(_ name: String, _ body: () throws -> Void) rethrows {
    reset(); try body(); count += 1; print("PASS \(name)")
}

try test("explicit provisioning stores device-only nonsynchronizing credential and wipes input") {
    var bytes = fixture
    let result = try saveDevicePasscode(&bytes)
    precondition(bytes.isEmpty && result["saved"] as? Bool == true && unlockCalls == 0)
    precondition(item![kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    precondition(item![kSecValueData as String] as? Data == Data(fixture))
    precondition(result["data"] == nil && result["passcode"] == nil)
}
try test("saved unlock forwards full unlock and returns metadata without a credential") {
    var bytes = fixture; _ = try saveDevicePasscode(&bytes)
    let result = try unlockWithSavedPasscode(limit: 2)
    precondition(unlockCalls == 1 && dismissed && suppliedLimit == 2 && !checked)
    precondition(result["passcode_source"] as? String == "device_keychain" && result["data"] == nil)
}
try test("check passes the same full-unlock preflight flag") {
    var bytes = fixture; _ = try saveDevicePasscode(&bytes)
    _ = try unlockWithSavedPasscode(checkOnly: true)
    precondition(checked && dismissed && unlockCalls == 1)
}
test("missing credential makes no unlock call") {
    expectError { _ = try unlockWithSavedPasscode() }
    precondition(unlockCalls == 0 && reads == 1)
}
test("inaccessible credential makes no unlock call or authentication prompt") {
    readStatus = errSecInteractionNotAllowed
    expectError { _ = try unlockWithSavedPasscode() }
    precondition(unlockCalls == 0)
}
test("Keychain error makes no unlock call") {
    readStatus = errSecMissingEntitlement
    expectError { _ = try unlockWithSavedPasscode() }
    precondition(unlockCalls == 0)
}
test("non-root is refused before accessing a credential") {
    fakeUID = 501
    expectError { _ = try unlockWithSavedPasscode() }
    expectError { _ = try removeSavedDevicePasscode() }
    var bytes = fixture
    expectError { _ = try saveDevicePasscode(&bytes) }
    precondition(bytes.isEmpty && reads == 0 && adds == 0 && updates == 0 && deletes == 0 && unlockCalls == 0)
}
test("invalid input is wiped without modifying storage") {
    for invalid in [[UInt8](), Array(repeating: UInt8(1), count: 129), [0], [10], [13]] {
        var bytes = invalid
        expectError { _ = try saveDevicePasscode(&bytes) }
        precondition(bytes.isEmpty)
    }
    precondition(adds == 0 && updates == 0 && unlockCalls == 0)
}
test("failed write wipes input and does not attempt an unlock") {
    writeStatus = errSecMissingEntitlement
    var bytes = fixture
    expectError { _ = try saveDevicePasscode(&bytes) }
    precondition(bytes.isEmpty && item == nil && unlockCalls == 0)
}
try test("updating storage does not delete the old item first") {
    var bytes = fixture; _ = try saveDevicePasscode(&bytes)
    bytes = fixture; _ = try saveDevicePasscode(&bytes)
    precondition(adds == 1 && updates == 2 && deletes == 0 && bytes.isEmpty)
}
try test("forget removes only the dedicated credential and is idempotent") {
    var bytes = fixture; _ = try saveDevicePasscode(&bytes)
    let first = try removeSavedDevicePasscode(), second = try removeSavedDevicePasscode()
    precondition(first["removed"] as? Bool == true && second["removed"] as? Bool == false && item == nil)
    precondition(unlockCalls == 0)
}
try test("engine failure is propagated without retry") {
    var bytes = fixture; _ = try saveDevicePasscode(&bytes)
    unlockThrows = true
    expectError { _ = try unlockWithSavedPasscode() }
    precondition(unlockCalls == 1)
}
print("PASS \(count) saved-passcode boundary cases")
