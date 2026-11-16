import Darwin
import Foundation

var fixtureHasSourceInformation = false
var writes: [[Double]] = []
var reads: [(Double, Bool, Double, Double)] = []
var clears = 0
var waits = 0
var writeError: String?
var readError: String?
var clearError: String?
var readings: [[String: Any]] = []
var passed = 0

func icli_string_free(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }
func fixtureLocationWait() { waits += 1 }
func json(_ value: [String: Any]) -> UnsafeMutablePointer<CChar>? {
    strdup(String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!)
}

func icli_location_simulate_json(_ lat: Double, _ lon: Double, _ alt: Double,
                                _ horizontal: Double, _ vertical: Double,
                                _ speed: Double, _ course: Double) -> UnsafeMutablePointer<CChar>? {
    writes.append([lat, lon, alt, horizontal, vertical, speed, course])
    return json(writeError.map { ["error": $0] } ?? [:])
}
func icli_location_clear_json() -> UnsafeMutablePointer<CChar>? {
    clears += 1
    return json(clearError.map { ["error": $0] } ?? [:])
}
func icli_location_read_json(_ timeout: Double, _ match: Bool,
                            _ lat: Double, _ lon: Double) -> UnsafeMutablePointer<CChar>? {
    reads.append((timeout, match, lat, lon))
    if let readError { return json(["error": readError]) }
    return json(readings.isEmpty ? fix(simulated: false) : readings.removeFirst())
}

func fix(lat: Double = 37.3, lon: Double = -122.0, fresh: Bool = true,
         simulated: Any = NSNull()) -> [String: Any] {
    ["latitude": lat, "longitude": lon, "fresh": fresh, "simulated": simulated]
}
func reset(modern: Bool = false) {
    fixtureHasSourceInformation = modern
    writes = []; reads = []; clears = 0; waits = 0
    writeError = nil; readError = nil; clearError = nil; readings = []
}
func check(_ name: String, _ work: () throws -> Void) rethrows {
    try work()
    passed += 1
    print("PASS \(name)")
}
func unavailable(_ work: () throws -> Void) {
    do { try work(); fatalError("expected unavailable") }
    catch IcliError.unavailable { }
    catch { fatalError("unexpected error: \(error)") }
}
func set() throws -> [String: Any] { try simulateLocation(latitude: 37.3, longitude: -122) }

try check("iOS 14 set sends request and preserves unknown simulation state") {
    reset(); readings = [fix()]
    let result = try set()
    assert(result["simulating"] is NSNull)
    assert((result["location"] as? [String: Any])?["simulated"] is NSNull)
    assert(writes == [[37.3, -122, 0, 5, 5, -1, -1]])
    assert(reads.count == 1 && reads[0].0 == 5 && reads[0].1)
    assert(reads[0].2 == 37.3 && reads[0].3 == -122 && clears == 0)
}
try check("iOS 14 clear sends stop and preserves unknown completion") {
    reset()
    let result = try clearSimulatedLocation()
    assert(result["simulating"] is NSNull)
    assert(clears == 1 && reads.isEmpty && waits == 0)
}
try check("newer set retains confirmed simulation state") {
    reset(modern: true); readings = [fix(simulated: true)]
    let result = try set()
    assert(result["simulating"] as? Bool == true)
    assert(writes.count == 1 && clears == 0)
}
try check("newer clear waits for the native source flag to clear") {
    reset(modern: true); readings = [fix(simulated: true), fix(simulated: false)]
    let result = try clearSimulatedLocation()
    assert(result["simulating"] as? Bool == false)
    assert(clears == 1 && reads.count == 2 && waits == 2)
}
check("iOS 14 stale reading fails and sends cleanup") {
    reset(); readings = [fix(fresh: false)]
    unavailable { _ = try set() }
    assert(writes.count == 1 && clears == 1 && reads.count == 1)
}
for (name, reading) in [("latitude", fix(lat: 1)), ("longitude", fix(lon: 1))] {
    check("iOS 14 wrong \(name) fails and sends cleanup") {
        reset(); readings = [reading]
        unavailable { _ = try set() }
        assert(clears == 1 && reads.count == 1)
    }
}
check("newer simulated flag cannot validate different coordinates") {
    reset(modern: true); readings = [fix(lat: 1, simulated: true)]
    unavailable { _ = try set() }
    assert(clears == 1)
}
for (name, flag) in [("unknown", NSNull() as Any), ("false", false as Any)] {
    check("newer \(name) source flag fails and sends cleanup") {
        reset(modern: true); readings = [fix(simulated: flag)]
        unavailable { _ = try set() }
        assert(clears == 1)
    }
}
check("iOS 14 read errors send cleanup and preserve error") {
    reset(); readError = "read refused"
    unavailable { _ = try set() }
    assert(clears == 1)
}
check("iOS 14 native write errors are not reported as requests sent") {
    reset(); writeError = "simulation unavailable"
    unavailable { _ = try set() }
    assert(writes.count == 1 && reads.isEmpty && clears == 0)
}
check("iOS 14 native clear errors stay errors") {
    reset(); clearError = "clear unavailable"
    unavailable { _ = try clearSimulatedLocation() }
    assert(clears == 1 && reads.isEmpty)
}
check("invalid coordinates fail before a native write") {
    for (lat, lon) in [(91.0, 0.0), (0.0, 181.0), (Double.nan, 0.0), (0.0, Double.infinity)] {
        reset()
        do { _ = try simulateLocation(latitude: lat, longitude: lon); fatalError("expected invalid input") }
        catch IcliError.failed { }
        catch { fatalError("unexpected error: \(error)") }
        assert(writes.isEmpty && reads.isEmpty && clears == 0)
    }
}
try check("iOS 14 current location preserves the native unknown flag") {
    reset(); readings = [fix()]
    let result = try currentLocation(timeout: 2)
    assert(result["simulated"] is NSNull)
    assert(writes.isEmpty && clears == 0 && reads.count == 1 && !reads[0].1)
}
try check("boundary coordinates and requested location fields are forwarded") {
    reset(); readings = [fix(lat: -90, lon: 180)]
    let result = try simulateLocation(latitude: -90, longitude: 180, altitude: -10,
                                      horizontalAccuracy: 0, verticalAccuracy: -1, speed: 2, course: 359)
    assert(result["simulating"] is NSNull)
    assert(writes == [[-90, 180, -10, 0, -1, 2, 359]])
}
print("\(passed) location compatibility checks passed")
