import CoreGraphics
import Foundation
import IcliPrivate
import UIKit

/// A rectangle of the screen, in points.
public struct ScreenRegion {
    let rect: CGRect

    /// Parses `x,y,width,height`; nil text means the whole screen.
    public init?(text: String?) throws {
        guard let text else { return nil }
        let parts = text.split(separator: ",").map { Double($0) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3],
              x >= 0, y >= 0, width > 0, height > 0, [x, y, width, height].allSatisfy(\.isFinite)
        else {
            throw IcliError.failed("region must be x,y,width,height in points")
        }
        rect = CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A small grayscale copy of the screen. Downsampling keeps each comparison
/// cheap and averages away JPEG noise.
private struct ScreenSample {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(image: CGImage, region: ScreenRegion?) throws {
        var source = image
        if let region {
            let metrics = icli_screen_metrics()
            let scale = CGFloat(image.width) / CGFloat(metrics.width)
            let crop = CGRect(x: region.rect.minX * scale, y: region.rect.minY * scale,
                              width: region.rect.width * scale, height: region.rect.height * scale).integral
            guard let cropped = image.cropping(to: crop) else {
                throw IcliError.failed("region is outside the screen")
            }
            source = cropped
        }
        let longest = max(source.width, source.height)
        let scale = min(1, 416 / Double(longest))
        let width = max(Int(Double(source.width) * scale), 1), height = max(Int(Double(source.height) * scale), 1)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw IcliError.failed("screen sampling failed") }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The fraction of pixels that moved by more than JPEG noise does. A
    /// different shape, as after a rotation, counts as completely different.
    func difference(from other: ScreenSample) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var changed = 0
        for index in pixels.indices where abs(Int(pixels[index]) - Int(other.pixels[index])) > 16 {
            changed += 1
        }
        return Double(changed) / Double(pixels.count)
    }
}

private func captureScreenSample(region: ScreenRegion?) throws -> ScreenSample {
    try requireCaptureCoordinateSpace()
    guard let image = icli_screen_cgimage(false) else { throw IcliError.failed("screenshot failed") }
    return try ScreenSample(image: image, region: region)
}

/// Waits for the screen to differ from a baseline, to hold still, or to differ
/// and then hold still. A timeout is a failure and reports what was last seen.
public func waitForScreen(
    changed: Bool,
    stable: Bool,
    baseline: String? = nil,
    stableFor: TimeInterval = 0.5,
    region: ScreenRegion? = nil,
    threshold: Double = 0.001,
    timeout: TimeInterval = 10,
    interval: TimeInterval = 0.05,
) throws -> [String: Any] {
    guard changed || stable else { throw IcliError.failed("provide --changed, --stable or both") }
    guard baseline == nil || changed else { throw IcliError.failed("--baseline applies only with --changed") }
    guard timeout.isFinite, (0 ... 60).contains(timeout), interval.isFinite, (0 ... 5).contains(interval),
          stableFor.isFinite, (0 ... 30).contains(stableFor), threshold.isFinite, (0 ... 1).contains(threshold)
    else {
        throw IcliError.failed("timeout must be 0–60, interval 0–5, stable-for 0–30 seconds and threshold 0–1")
    }
    icli_private_init()
    let reference: ScreenSample
    if let baseline {
        guard let image = UIImage(contentsOfFile: baseline)?.cgImage else {
            throw IcliError.failed("baseline is not a readable image: \(baseline)")
        }
        reference = try ScreenSample(image: image, region: region)
    } else {
        reference = try captureScreenSample(region: region)
    }
    return try waitForScreen(
        from: reference, changed: changed, stable: stable, stableFor: stableFor, region: region,
        threshold: threshold, timeout: timeout, interval: interval,
    )
}

/// Opens a URL and waits, by the frames shown, until the screen differs from
/// how it was before. A screen that did not change within `timeout` is
/// `screen_changed: false`, not a failure.
public func openURL(_ url: String, checkingChangeFor timeout: TimeInterval) throws -> [String: Any] {
    guard timeout.isFinite, (0 ... 60).contains(timeout) else { throw IcliError.failed("timeout must be 0–60 seconds") }
    icli_private_init()
    let reference = try captureScreenSample(region: nil)
    var result = try openURL(url)
    do {
        let waited = try waitForScreen(
            from: reference, changed: true, stable: false, stableFor: 0, region: nil,
            threshold: 0.001, timeout: timeout, interval: 0.05,
        )
        result["screen_changed"] = true
        result["changed_ms"] = waited["changed_ms"]
    } catch let IcliError.commandFailed(failure) where failure["error"] as? String == "timed_out" {
        result["screen_changed"] = false
        result["message"] = "the screen did not change within \(timeout) s"
    }
    return result
}

private func waitForScreen(
    from reference: ScreenSample, changed: Bool, stable: Bool, stableFor: TimeInterval, region: ScreenRegion?,
    threshold: Double, timeout: TimeInterval, interval: TimeInterval,
) throws -> [String: Any] {
    let start = ProcessInfo.processInfo.systemUptime
    // A still screen draws no frames, so captures follow the frames shown and
    // a quiet spell ends only to confirm --stable-for or at the timeout.
    var gate = FrameGate()
    defer { gate.close() }

    var previous = reference
    var frames = 0
    var changeSeen = !changed
    var changedAt: Double?
    var settledSince = ProcessInfo.processInfo.systemUptime
    var lastDifference = 0.0
    while true {
        gate.mark()
        let frame = try captureScreenSample(region: region)
        let now = ProcessInfo.processInfo.systemUptime
        frames += 1
        lastDifference = frame.difference(from: reference)
        if frame.difference(from: previous) > threshold { settledSince = now }
        if !changeSeen, lastDifference > threshold {
            changeSeen = true
            changedAt = now - start
            settledSince = now
        }
        previous = frame
        if changeSeen, !stable || now - settledSince >= stableFor {
            var result: [String: Any] = [
                "waited_ms": Int((now - start) * 1000), "frames": frames, "difference": lastDifference,
                "trigger": gate.trigger,
            ]
            if changed {
                result["changed"] = true
                result["changed_ms"] = Int((changedAt ?? 0) * 1000)
            }
            if stable {
                result["stable"] = true
                result["stable_ms"] = Int((now - settledSince) * 1000)
            }
            return result
        }
        if now - start >= timeout {
            throw IcliError.commandFailed([
                "error": "timed_out",
                "message": changeSeen ? "the screen kept changing" : "the screen did not change",
                "waited_ms": Int((now - start) * 1000), "frames": frames, "difference": lastDifference,
                "changed": changeSeen && changed,
                "trigger": gate.trigger,
                "status": 1,
            ])
        }
        var limit = timeout - (now - start)
        if changeSeen, stable { limit = min(limit, stableFor - (now - settledSince)) }
        _ = gate.wait(limit: limit, interval: interval, since: now)
    }
}
