import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IcliPrivate

/// Records the screen to a QuickTime movie. Frames are drawn straight into the
/// encoder's own buffers, so nothing is copied. The movie appears at its path
/// only once it is complete, so a failure leaves nothing to mistake for it.
public func recordScreen(seconds: Double?, path requested: String?, fps: Int, codec: String) throws -> [String: Any] {
    let limit = 3600.0
    if let seconds, !seconds.isFinite || seconds <= 0 || seconds > limit {
        throw IcliError.failed("seconds must be more than 0, up to 3600")
    }
    guard (1 ... 60).contains(fps) else { throw IcliError.failed("fps must be 1–60") }
    let codecs: [String: AVVideoCodecType] = ["hevc": .hevc, "h264": .h264]
    guard let codecType = codecs[codec] else { throw IcliError.failed("codec must be hevc or h264") }
    var width: Int32 = 0, height: Int32 = 0
    icli_panel_pixels(&width, &height)
    guard width > 0, height > 0 else { throw IcliError.failed("the display's size is unavailable") }
    let path = requested ?? (JailbreakRoot.current.scratchDirectory() + "/icli-\(UUID().uuidString).mov")
    let partial = path + ".partial"
    try? FileManager.default.removeItem(atPath: partial)
    defer { try? FileManager.default.removeItem(atPath: partial) }

    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: partial), fileType: .mov)
    let settings: [String: Any] = [AVVideoCodecKey: codecType, AVVideoWidthKey: Int(width), AVVideoHeightKey: Int(height)]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
        throw IcliError.unavailable("This device cannot encode \(codec) at \(width)x\(height).")
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    // The render server draws in the panel's orientation; the movie says how to turn it.
    input.transform = CGAffineTransform(rotationAngle: Double(icli_interface_degrees()) * .pi / 180)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(width),
        kCVPixelBufferHeightKey as String: Int(height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])
    writer.add(input)
    guard writer.startWriting() else {
        throw IcliError.failed("recording could not start: \(writer.error?.localizedDescription ?? "unknown error")")
    }
    writer.startSession(atSourceTime: .zero)

    icli_stop_signals_catch()
    defer { icli_stop_signals_release() }

    let duration = seconds ?? limit
    let interval = 1 / Double(fps)
    let start = ProcessInfo.processInfo.systemUptime
    var frames = 0, dropped = 0, tick = 0
    var stoppedBy = "seconds"
    while true {
        let now = ProcessInfo.processInfo.systemUptime - start
        if now >= duration || writer.status != .writing { break }
        var buffer: CVPixelBuffer?
        if input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool,
           CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
           let surface = CVPixelBufferGetIOSurface(buffer)
        {
            guard icli_render_display(Unmanaged.passUnretained(surface.takeUnretainedValue()).toOpaque()) else {
                writer.cancelWriting()
                throw IcliError.unavailable("The render server is unavailable on this device.")
            }
            if adaptor.append(buffer, withPresentationTime: CMTime(seconds: now, preferredTimescale: 6000)) {
                frames += 1
            }
        } else {
            dropped += 1
        }
        // A frame that overran its slot takes the next ones with it.
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let due = Int(elapsed / interval) + 1
        dropped += max(0, due - tick - 1)
        tick = due
        if icli_stop_signal_wait(max(0, Double(due) * interval - elapsed)) {
            stoppedBy = "signal"
            break
        }
    }
    let recorded = ProcessInfo.processInfo.systemUptime - start
    guard writer.status == .writing else {
        let reason = writer.error?.localizedDescription ?? "unknown error"
        writer.cancelWriting()
        throw IcliError.failed("recording failed: \(reason)")
    }
    guard frames > 0 else {
        writer.cancelWriting()
        throw IcliError.failed("recording failed: no frames were captured")
    }
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    finished.wait()
    guard writer.status == .completed else {
        throw IcliError.failed("recording failed: \(writer.error?.localizedDescription ?? "unknown error")")
    }
    guard rename(partial, path) == 0 else {
        throw IcliError.failed("could not write \(path): \(String(cString: strerror(errno)))")
    }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    return [
        "path": path, "seconds": recorded, "frames": frames, "dropped": dropped, "fps": Double(frames) / recorded,
        "width": Int(width), "height": Int(height), "codec": codec, "bytes": bytes, "stopped_by": stoppedBy,
        "mime_type": "video/quicktime",
    ]
}
