import Foundation

extension Array where Element == String {
    /// Calls `body` with these strings as a C array, valid only during the call.
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let copies = map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers = copies.map { $0.map { UnsafePointer($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
