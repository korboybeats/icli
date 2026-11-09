import CommonCrypto
import Foundation
import IcliSystem

// Ad-hoc code signing, written for icli: the signature `codesign -s -` makes
// for an iOS binary, byte for byte. A SHA-256 CodeDirectory (version 0x20400,
// flags CS_ADHOC, 4 KiB pages, the executable segment of __TEXT), an empty
// requirement set, the entitlements as XML and DER, and an empty CMS wrapper.
// Every 64-bit slice of a thin or universal Mach-O is signed in place.

private let pageShift: UInt8 = 12
private let pageSize = 1 << 12
private let linkeditAlignment = 0x4000

private enum Magic {
    static let machO64: UInt32 = 0xFEED_FACF
    static let fat: UInt32 = 0xCAFE_BABE
    static let fat64: UInt32 = 0xCAFE_BABF
    static let superBlob: UInt32 = 0xFADE_0CC0
    static let codeDirectory: UInt32 = 0xFADE_0C02
    static let requirements: UInt32 = 0xFADE_0C01
    static let entitlements: UInt32 = 0xFADE_7171
    static let derEntitlements: UInt32 = 0xFADE_7172
    static let blobWrapper: UInt32 = 0xFADE_0B01
}

private enum Command {
    static let segment64: UInt32 = 0x19
    static let codeSignature: UInt32 = 0x1D
    static let encryptionInfo64: UInt32 = 0x2C
}

/// What signing one file did.
struct AdhocSigningResult {
    /// Whether any slice is FairPlay encrypted (cryptid != 0).
    var encrypted = false
    var slices = 0
}

/// Decides a file's entitlements from the ones it is signed with now (nil
/// when it has none); a nil result signs it without entitlements.
typealias EntitlementsChoice = ([String: Any]?) throws -> [String: Any]?

private func fail(_ path: String, _ message: String) -> IcliError {
    IcliError.failed("cannot sign \(path): \(message)")
}

// MARK: - Byte access

private extension [UInt8] {
    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }

    func be32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    mutating func setU32(_ offset: Int, _ value: UInt32) {
        for i in 0 ..< 4 {
            self[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i)))
        }
    }

    mutating func setU64(_ offset: Int, _ value: UInt64) {
        setU32(offset, UInt32(truncatingIfNeeded: value))
        setU32(offset + 4, UInt32(truncatingIfNeeded: value >> 32))
    }

    mutating func setBE32(_ offset: Int, _ value: UInt32) {
        for i in 0 ..< 4 {
            self[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(3 - i)))
        }
    }

    mutating func appendBE32(_ value: UInt32) {
        append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    mutating func appendBE64(_ value: UInt64) {
        appendBE32(UInt32(truncatingIfNeeded: value >> 32))
        appendBE32(UInt32(truncatingIfNeeded: value))
    }
}

private func sha256<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    let hashed: Void? = bytes.withContiguousStorageIfAvailable { buffer in
        _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
    }
    if hashed == nil {
        let copy = [UInt8](bytes)
        _ = CC_SHA256(copy, CC_LONG(copy.count), &digest)
    }
    return digest
}

private func align(_ value: Int, _ alignment: Int) -> Int {
    (value + alignment - 1) / alignment * alignment
}

private func blob(_ magic: UInt32, _ payload: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.appendBE32(magic)
    bytes.appendBE32(UInt32(8 + payload.count))
    return bytes + payload
}

// MARK: - DER entitlements

/// The DER form iOS 15 and later read entitlements from: [APPLICATION 16]
/// { INTEGER 1, dictionary }, a dictionary being [CONTEXT 16] { SEQUENCE
/// { UTF8String key, value } ... } in key order. Booleans, integers,
/// strings, arrays and dictionaries are representable; anything else is not.
func derEntitlements(_ entitlements: [String: Any]) throws -> [UInt8] {
    func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    func element(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }
    func integer(_ value: Int64) -> [UInt8] {
        var bytes = (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * Int64($0))) }
        while bytes.count > 1, (bytes[0] == 0 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0) {
            bytes.removeFirst()
        }
        return element(0x02, bytes)
    }
    func value(_ item: Any, _ key: String) throws -> [UInt8] {
        switch item {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return element(0x01, [number.boolValue ? 0xFF : 0x00])
        case let number as NSNumber:
            guard !CFNumberIsFloatType(number) else {
                throw IcliError.failed("entitlement \(key) is a real number, which signed entitlements cannot hold")
            }
            return integer(number.int64Value)
        case let string as String:
            return element(0x0C, Array(string.utf8))
        case let array as [Any]:
            return try element(0x30, array.flatMap { try value($0, key) })
        case let dictionary as [String: Any]:
            return try encode(dictionary)
        default:
            throw IcliError.failed("entitlement \(key) is a \(type(of: item)), which signed entitlements cannot hold")
        }
    }
    func encode(_ dictionary: [String: Any]) throws -> [UInt8] {
        let pairs = try dictionary.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }.flatMap { key in
            try element(0x30, element(0x0C, Array(key.utf8)) + value(dictionary[key]!, key))
        }
        return element(0xB0, pairs)
    }
    return try element(0x70, integer(1) + encode(entitlements))
}

// MARK: - One slice

/// codesign's executable segment flags, measured: a main executable gets
/// CS_EXECSEG_MAIN_BINARY plus one flag for each of these entitlements that
/// is the boolean true; a library gets none.
private func executableSegmentFlags(fileType: UInt32, _ entitlements: [String: Any]?) -> UInt64 {
    guard fileType == 2 else { return 0 } // MH_EXECUTE
    let flags: [(String, UInt64)] = [
        ("get-task-allow", 0x10), ("run-unsigned-code", 0x10), // CS_EXECSEG_ALLOW_UNSIGNED
        ("com.apple.private.cs.debugger", 0x20), ("dynamic-codesigning", 0x40),
        ("com.apple.private.skip-library-validation", 0x80),
        ("com.apple.private.amfi.can-load-cdhash", 0x100), ("com.apple.private.amfi.can-execute-cdhash", 0x200),
    ]
    return flags.reduce(1) { result, flag in
        guard let value = entitlements?[flag.0] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue else {
            return result
        }
        return result | flag.1
    }
}

private struct SliceLayout {
    var fileType: UInt32 = 0
    var commandsEnd = 0
    var firstSectionOffset = Int.max
    var textOffset = 0
    var textSize = 0
    var linkeditCommand: Int?
    var signatureCommand: Int?
    var encrypted = false
}

private func layout(of slice: [UInt8], _ path: String) throws -> SliceLayout {
    guard slice.count >= 32, slice.u32(0) == Magic.machO64 else { throw fail(path, "not a 64-bit Mach-O slice") }
    var result = SliceLayout()
    result.fileType = slice.u32(12)
    let count = Int(slice.u32(16)), size = Int(slice.u32(20))
    guard 32 + size <= slice.count else { throw fail(path, "load commands run past the file") }
    result.commandsEnd = 32 + size
    var offset = 32
    for _ in 0 ..< count {
        guard offset + 8 <= result.commandsEnd else { throw fail(path, "truncated load command") }
        let command = slice.u32(offset), commandSize = Int(slice.u32(offset + 4))
        guard commandSize >= 8, offset + commandSize <= result.commandsEnd else { throw fail(path, "invalid load command size") }
        switch command {
        case Command.segment64:
            guard commandSize >= 72 else { throw fail(path, "invalid segment command") }
            let name = String(decoding: slice[offset + 8 ..< offset + 24].prefix { $0 != 0 }, as: UTF8.self)
            if name == "__TEXT" {
                result.textOffset = Int(slice.u64(offset + 40))
                result.textSize = Int(slice.u64(offset + 48))
            } else if name == "__LINKEDIT" {
                result.linkeditCommand = offset
            }
            let sections = Int(slice.u32(offset + 64))
            guard 72 + sections * 80 <= commandSize else { throw fail(path, "invalid section count") }
            for i in 0 ..< sections {
                let sectionOffset = Int(slice.u32(offset + 72 + i * 80 + 48))
                if sectionOffset > 0 {
                    result.firstSectionOffset = min(result.firstSectionOffset, sectionOffset)
                }
            }
        case Command.codeSignature:
            guard commandSize >= 16 else { throw fail(path, "invalid signature command") }
            result.signatureCommand = offset
        case Command.encryptionInfo64:
            guard commandSize >= 20 else { throw fail(path, "invalid encryption command") }
            result.encrypted = slice.u32(offset + 16) != 0
        default:
            break
        }
        offset += commandSize
    }
    return result
}

/// The identifier and XML entitlements of a slice's current signature.
private func currentSignature(_ slice: [UInt8], _ layout: SliceLayout) -> (identifier: String?, entitlements: [String: Any]?) {
    guard let command = layout.signatureCommand else { return (nil, nil) }
    let start = Int(slice.u32(command + 8)), size = Int(slice.u32(command + 12))
    guard size >= 12, start >= 0, start <= slice.count - size, slice.be32(start) == Magic.superBlob else { return (nil, nil) }
    let count = Int(slice.be32(start + 8))
    guard count <= (size - 12) / 8 else { return (nil, nil) }
    var identifier: String?
    var entitlements: [String: Any]?
    for i in 0 ..< count {
        let type = slice.be32(start + 12 + i * 8), relative = Int(slice.be32(start + 16 + i * 8))
        guard relative <= size - 8 else { continue }
        let blobStart = start + relative, blobSize = Int(slice.be32(blobStart + 4))
        guard blobSize >= 8, relative + blobSize <= size else { continue }
        let magic = slice.be32(blobStart)
        if type == 0, magic == Magic.codeDirectory, blobSize >= 24 {
            let identOffset = Int(slice.be32(blobStart + 20))
            if identOffset < blobSize {
                identifier = String(decoding: slice[blobStart + identOffset ..< blobStart + blobSize].prefix { $0 != 0 }, as: UTF8.self)
            }
        } else if type == 5, magic == Magic.entitlements {
            let xml = Data(slice[blobStart + 8 ..< blobStart + blobSize])
            entitlements = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        }
    }
    return (identifier, entitlements)
}

private func signSlice(
    _ input: [UInt8],
    path: String,
    identifier: String?,
    entitlements choose: EntitlementsChoice,
) throws -> (slice: [UInt8], encrypted: Bool) {
    var slice = input
    let info = try layout(of: slice, path)
    guard let linkedit = info.linkeditCommand else { throw fail(path, "no __LINKEDIT segment") }
    let linkeditOffset = Int(slice.u64(linkedit + 40)), linkeditSize = Int(slice.u64(linkedit + 48))
    let current = currentSignature(slice, info)
    let name = identifier ?? current.identifier ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    guard !name.isEmpty else { throw fail(path, "no signing identifier") }
    let entitlements = try choose(current.entitlements)

    // The signature replaces the current one, or goes after the last
    // segment, which must be __LINKEDIT, behind a new load command.
    let codeLimit: Int
    if let command = info.signatureCommand {
        codeLimit = Int(slice.u32(command + 8))
        guard codeLimit >= linkeditOffset, codeLimit <= slice.count else { throw fail(path, "the signature lies outside __LINKEDIT") }
    } else {
        guard linkeditOffset + linkeditSize == slice.count else { throw fail(path, "__LINKEDIT does not end the file") }
        guard info.commandsEnd + 16 <= info.firstSectionOffset else { throw fail(path, "no room for a signature load command") }
        codeLimit = align(slice.count, 16)
    }
    guard codeLimit <= Int(UInt32.max) else { throw fail(path, "larger than 4 GiB") }

    var requirements: [UInt8] = []
    requirements.appendBE32(Magic.requirements)
    requirements.appendBE32(12)
    requirements.appendBE32(0)
    let xml = try entitlements.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) }
    let xmlBlob = xml.map { blob(Magic.entitlements, Array($0)) }
    let derBlob = try entitlements.map { try blob(Magic.derEntitlements, derEntitlements($0)) }
    let wrapper = blob(Magic.blobWrapper, [])

    let specialSlots = entitlements == nil ? 2 : 7
    let codeSlots = (codeLimit + pageSize - 1) / pageSize
    let identBytes = Array(name.utf8) + [0]
    let directoryHeader = 88
    let hashOffset = directoryHeader + identBytes.count + specialSlots * 32
    let directorySize = hashOffset + codeSlots * 32
    var blobs: [(UInt32, Int)] = [(0, directorySize), (2, requirements.count)]
    if let xmlBlob, let derBlob {
        blobs += [(5, xmlBlob.count), (7, derBlob.count)]
    }
    blobs.append((0x10000, wrapper.count))
    let superSize = 12 + blobs.count * 8 + blobs.reduce(0) { $0 + $1.1 }
    let reserved = align(superSize, 16)

    // Header changes come first: they are inside the hashed pages.
    if let command = info.signatureCommand {
        slice.setU32(command + 12, UInt32(reserved))
        slice.removeSubrange(codeLimit...)
    } else {
        let command = info.commandsEnd
        slice.setU32(command, Command.codeSignature)
        slice.setU32(command + 4, 16)
        slice.setU32(command + 8, UInt32(codeLimit))
        slice.setU32(command + 12, UInt32(reserved))
        slice.setU32(16, slice.u32(16) + 1)
        slice.setU32(20, slice.u32(20) + 16)
        slice += [UInt8](repeating: 0, count: codeLimit - slice.count)
    }
    let newLinkeditSize = codeLimit + reserved - linkeditOffset
    slice.setU64(linkedit + 48, UInt64(newLinkeditSize))
    slice.setU64(linkedit + 32, UInt64(align(newLinkeditSize, linkeditAlignment)))

    // special[n - k] holds the hash for slot -k.
    var special = [[UInt8]](repeating: [UInt8](repeating: 0, count: 32), count: specialSlots)
    special[specialSlots - 2] = sha256(requirements)
    if let xmlBlob, let derBlob {
        special[specialSlots - 5] = sha256(xmlBlob)
        special[specialSlots - 7] = sha256(derBlob)
    }
    var directory: [UInt8] = []
    directory.reserveCapacity(directorySize)
    directory.appendBE32(Magic.codeDirectory)
    directory.appendBE32(UInt32(directorySize))
    directory.appendBE32(0x20400)
    directory.appendBE32(0x2) // CS_ADHOC
    directory.appendBE32(UInt32(hashOffset))
    directory.appendBE32(UInt32(directoryHeader))
    directory.appendBE32(UInt32(specialSlots))
    directory.appendBE32(UInt32(codeSlots))
    directory.appendBE32(UInt32(codeLimit))
    directory += [32, 2, 0, pageShift] // SHA-256 hashes, no platform
    directory.appendBE32(0) // spare2
    directory.appendBE32(0) // scatter
    directory.appendBE32(0) // team
    directory.appendBE32(0) // spare3
    directory.appendBE64(0) // codeLimit64
    directory.appendBE64(UInt64(info.textOffset))
    directory.appendBE64(UInt64(info.textSize))
    directory.appendBE64(executableSegmentFlags(fileType: info.fileType, entitlements))
    directory += identBytes
    for hash in special { // slot -n first, -1 last
        directory += hash
    }
    slice.withUnsafeBufferPointer { buffer in
        for page in 0 ..< codeSlots {
            let start = page * pageSize
            directory += sha256(UnsafeBufferPointer(rebasing: buffer[start ..< min(start + pageSize, codeLimit)]))
        }
    }

    var signature: [UInt8] = []
    signature.appendBE32(Magic.superBlob)
    signature.appendBE32(UInt32(superSize))
    signature.appendBE32(UInt32(blobs.count))
    var offset = 12 + blobs.count * 8
    for (type, size) in blobs {
        signature.appendBE32(type)
        signature.appendBE32(UInt32(offset))
        offset += size
    }
    signature += directory + requirements
    if let xmlBlob, let derBlob {
        signature += xmlBlob + derBlob
    }
    signature += wrapper
    slice += signature + [UInt8](repeating: 0, count: reserved - superSize)
    return (slice, info.encrypted)
}

// MARK: - Files

/// Whether the file at `path` starts like a 64-bit or universal Mach-O.
func looksLikeMachO(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
    let value = magic.withUnsafeBytes { $0.load(as: UInt32.self) }
    return [0xFEED_FACF, 0xBEBA_FECA, 0xBFBA_FECA].contains(value)
}

/// The Mach-O file type (MH_EXECUTE 2, MH_DYLIB 6, MH_BUNDLE 8, ...) of the
/// file's first 64-bit slice, or nil if it has none.
func machOFileType(_ path: String) -> UInt32? {
    // Read, never mapped (see machOSigning).
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= 16 else { return nil }
    let bytes = [UInt8](data.prefix(4096))
    if bytes.u32(0) == Magic.machO64 { return bytes.u32(12) }
    guard bytes.be32(0) == Magic.fat else { return nil }
    let count = Int(bytes.be32(4))
    for i in 0 ..< min(count, 128) where 8 + i * 20 + 20 <= bytes.count {
        let offset = Int(bytes.be32(8 + i * 20 + 8))
        guard offset + 16 <= data.count else { continue }
        let header = [UInt8](data[offset ..< offset + 16])
        if header.u32(0) == Magic.machO64 { return header.u32(12) }
    }
    return nil
}

/// Signs every 64-bit slice of the Mach-O at `path` ad-hoc, in place.
/// `identifier` nil keeps the current one (or the file name without its
/// extension); `entitlements` picks the entitlements from the current ones.
/// A universal file keeps its other slices, moved to fit the new sizes.
@discardableResult
func signAdhoc(
    _ path: String,
    identifier: String? = nil,
    entitlements: EntitlementsChoice = { $0 },
) throws -> AdhocSigningResult {
    let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
    guard bytes.count >= 8 else { throw fail(path, "too small for a Mach-O") }
    var result = AdhocSigningResult()
    let output: [UInt8]
    if bytes.u32(0) == Magic.machO64 {
        let signed = try signSlice(bytes, path: path, identifier: identifier, entitlements: entitlements)
        result.encrypted = signed.encrypted
        result.slices = 1
        output = signed.slice
    } else if bytes.be32(0) == Magic.fat {
        let count = Int(bytes.be32(4))
        guard count > 0, count <= 64, 8 + count * 20 <= bytes.count else { throw fail(path, "invalid universal header") }
        var slices: [(cpu: UInt32, subtype: UInt32, align: UInt32, bytes: [UInt8])] = []
        for i in 0 ..< count {
            let entry = 8 + i * 20
            let offset = Int(bytes.be32(entry + 8)), size = Int(bytes.be32(entry + 12)), alignment = bytes.be32(entry + 16)
            guard offset >= 8 + count * 20, size > 0, offset <= bytes.count - size, alignment < 32 else {
                throw fail(path, "invalid universal slice")
            }
            var slice = Array(bytes[offset ..< offset + size])
            if slice.u32(0) == Magic.machO64 {
                let signed = try signSlice(slice, path: path, identifier: identifier, entitlements: entitlements)
                slice = signed.slice
                result.encrypted = result.encrypted || signed.encrypted
                result.slices += 1
            }
            slices.append((bytes.be32(entry), bytes.be32(entry + 4), alignment, slice))
        }
        guard result.slices > 0 else { throw fail(path, "no 64-bit slice") }
        var header: [UInt8] = []
        header.appendBE32(Magic.fat)
        header.appendBE32(UInt32(count))
        var body: [UInt8] = []
        var position = 8 + count * 20
        for slice in slices {
            let start = align(position, 1 << Int(slice.align))
            guard start + slice.bytes.count <= Int(UInt32.max) else { throw fail(path, "larger than 4 GiB") }
            body += [UInt8](repeating: 0, count: start - position) + slice.bytes
            header.appendBE32(slice.cpu)
            header.appendBE32(slice.subtype)
            header.appendBE32(UInt32(start))
            header.appendBE32(UInt32(slice.bytes.count))
            header.appendBE32(slice.align)
            position = start + slice.bytes.count
        }
        output = header + body
    } else if bytes.be32(0) == Magic.fat64 {
        throw fail(path, "64-bit universal files are not supported")
    } else {
        throw fail(path, "not a 64-bit Mach-O")
    }
    // Written beside the file and renamed over it, keeping its mode.
    let temporary = path + ".icli-signing"
    guard FileManager.default.createFile(atPath: temporary, contents: Data(output)) else {
        throw fail(path, "could not write \(temporary)")
    }
    do {
        if let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary)
        }
        guard rename(temporary, path) == 0 else { throw fail(path, String(cString: strerror(errno))) }
    } catch {
        try? FileManager.default.removeItem(atPath: temporary)
        throw error
    }
    return result
}

// MARK: - App bundles

/// The executable `path` is the main binary of, if any: its directory's
/// Info.plist names it as CFBundleExecutable.
private func bundleInfo(ofExecutable path: String) -> [String: Any]? {
    let directory = (path as NSString).deletingLastPathComponent
    guard let info = NSDictionary(contentsOfFile: directory + "/Info.plist") as? [String: Any],
          info["CFBundleExecutable"] as? String == (path as NSString).lastPathComponent else { return nil }
    return info
}

/// Signs every Mach-O executable, library and plug-in in `app` ad-hoc, the
/// way TrollStore Lite has ldid sign an app it installs. Each app and app
/// extension main binary is signed as its CFBundleIdentifier with its own
/// entitlements plus jb.pmap_cs.custom_trust = PMAP_CS_APP_STORE, so a
/// Dopamine device runs it at App Store trust rather than the loaded trust
/// cache level; an app binary with no entitlements gets the ones Xcode gives
/// a development app. Other binaries keep their identifier and entitlements.
/// An encrypted main binary is refused; other encrypted binaries are listed.
func signAppBundle(_ app: String) throws -> [String: Any] {
    guard let info = NSDictionary(contentsOfFile: app + "/Info.plist") as? [String: Any],
          let executable = info["CFBundleExecutable"] as? String else {
        throw IcliError.failed("cannot sign \(app): no CFBundleExecutable")
    }
    let main = app + "/" + executable
    if try machOSigning(at: main).encrypted {
        throw IcliError.failed("\(executable) is FairPlay encrypted; decrypt the app before installing it")
    }
    var files: [String] = []
    if let entries = FileManager.default.enumerator(atPath: app) {
        for case let relative as String in entries {
            let path = app + "/" + relative
            var status = stat()
            guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, looksLikeMachO(path),
                  let type = machOFileType(path), [2, 6, 8].contains(type) else { continue } // EXECUTE, DYLIB, BUNDLE
            files.append(relative)
        }
    }
    var encrypted: [String] = []
    for relative in files.sorted() {
        let path = app + "/" + relative
        let bundle = bundleInfo(ofExecutable: path)
        let identifier = bundle?["CFBundleIdentifier"] as? String
        let result: AdhocSigningResult
        if let bundle, bundle["CFBundlePackageType"] as? String != "FMWK" {
            let isApp = path == main
            result = try signAdhoc(path, identifier: identifier) { current in
                var entitlements = current ?? (isApp ? [
                    "application-identifier": "0000000000.*",
                    "com.apple.developer.team-identifier": "0000000000",
                    "get-task-allow": true,
                    "keychain-access-groups": ["0000000000.*", "com.apple.token"],
                ] : [:])
                entitlements["jb.pmap_cs.custom_trust"] = "PMAP_CS_APP_STORE"
                return entitlements
            }
        } else {
            result = try signAdhoc(path, identifier: identifier)
        }
        if result.encrypted {
            encrypted.append(relative)
        }
    }
    return ["signed_binaries": files.count, "encrypted_binaries": encrypted]
}
