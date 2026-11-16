import CoreGraphics
import Foundation
import ImageIO
import IcliLaunchPrivate

/// Hidden app sessions from the Parallel package (com.korboy.parallel): its
/// broker in SpringBoard launches an app into a scene that is never shown, and
/// sends that app touches, text and keys and captures it, while the person
/// keeps using the phone. A session's token, not the device lease, authorizes
/// work on it, so several runners can each drive their own app at once.
public enum Parallel {
    /// The broker protocol this client speaks; `ping` reports the broker's.
    public static let protocolVersion = 1

    /// One broker request. Broker errors become icli errors carrying the
    /// broker's code (stale_generation, capacity, ...); keys come back in
    /// icli's snake_case.
    public static func request(_ op: String, _ fields: [String: Any] = [:], timeout: Double = 15) throws -> [String: Any] {
        var body = fields
        body["op"] = op
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        guard let raw = takeCString(icli_parallel_request_json(json, timeout)),
              let reply = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { throw IcliError.failed("Parallel's broker sent an invalid reply") }
        guard reply["ok"] as? Bool == true else {
            let code = reply["error"] as? String ?? "failed"
            var payload: [String: Any] = ["error": code, "message": reply["detail"] as? String ?? code]
            if code == "parallel_unavailable" { payload["status"] = 69 } // EX_UNAVAILABLE
            throw IcliError.commandFailed(payload)
        }
        var result = snakeCased(reply) as? [String: Any] ?? [:]
        result.removeValue(forKey: "ok")
        return result
    }

    static func snakeCased(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in dict { result[snakeCase(key)] = snakeCased(item) }
            return result
        }
        if let array = value as? [Any] { return array.map(snakeCased) }
        return value
    }

    private static func snakeCase(_ key: String) -> String {
        var out = ""
        for c in key { out += c.isUppercase ? "_" + c.lowercased() : String(c) }
        return out
    }
}

/// The session a command acts in: its ID, token and generation. The
/// generation is required for input and capture, so a command meant for an
/// app process that has since been restarted is refused (stale_generation).
public struct ParallelTarget {
    public let session: String
    public let token: String
    public let generation: Int?

    public init(session: String, token: String?, generation: Int?) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let token = token ?? environment["ICLI_PARALLEL_TOKEN"], !token.isEmpty else {
            throw IcliError.failed("a Parallel session needs its token: --parallel-token or ICLI_PARALLEL_TOKEN")
        }
        self.session = session
        self.token = token
        self.generation = generation ?? environment["ICLI_PARALLEL_GENERATION"].flatMap { Int($0) }
    }

    /// `ICLI_PARALLEL` names the session when no --parallel is given.
    public static func resolve(session: String?, token: String?, generation: Int?) throws -> ParallelTarget? {
        guard let session = session ?? ProcessInfo.processInfo.environment["ICLI_PARALLEL"], !session.isEmpty else { return nil }
        return try ParallelTarget(session: session, token: token, generation: generation)
    }

    func request(_ op: String, _ fields: [String: Any] = [:], timeout: Double = 15) throws -> [String: Any] {
        var body = fields
        body["session"] = session
        body["token"] = token
        if let generation { body["generation"] = generation }
        return try Parallel.request(op, body, timeout: timeout)
    }

    // MARK: Session lifecycle

    public func lifecycle(_ op: String, orientation: String? = nil) throws -> [String: Any] {
        var fields: [String: Any] = [:]
        if let orientation { fields["orientation"] = orientation }
        // A launch waits up to 30 s for the app to draw.
        return try request(op, fields, timeout: op == "launch" || op == "restart" ? 45 : 15)
    }

    /// The session app's process, for reading its accessibility tree.
    public func appPID() throws -> Int32 {
        let status = try request("status")
        guard status["state"] as? String == "ready", let pid = status["pid"] as? Int, pid > 0 else {
            throw IcliError.commandFailed(["error": "not_running", "message": "the session's app is not running"])
        }
        return Int32(pid)
    }

    // MARK: Input

    /// Touch frames at 60 per second: each lists the same 1–5 points; the
    /// first frame touches down, the last lifts.
    public func gesture(_ frames: [[[Double]]]) throws -> [String: Any] {
        try request("gesture", ["frames": frames], timeout: Double(frames.count) / 60 + 15)
    }

    public func tap(x: Double, y: Double, hold: Double = 0) throws -> [String: Any] {
        let count = max(2, Int((hold * 60).rounded()) + 1)
        return try gesture(Array(repeating: [[x, y]], count: count))
    }

    public func doubleTap(x: Double, y: Double, interval: Double) throws -> [String: Any] {
        _ = try tap(x: x, y: y)
        Thread.sleep(forTimeInterval: interval)
        return try tap(x: x, y: y)
    }

    public func swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double) throws -> [String: Any] {
        let steps = max(2, Int((seconds * 60).rounded()))
        let frames = (0 ... steps).map { i -> [[Double]] in
            let f = Double(i) / Double(steps)
            return [[x1 + (x2 - x1) * f, y1 + (y2 - y1) * f]]
        }
        return try gesture(frames)
    }

    public func pinch(x: Double, y: Double, from: Double, to: Double, angle: Double, seconds: Double) throws -> [String: Any] {
        let steps = max(2, Int((seconds * 60).rounded()))
        let dx = cos(angle * .pi / 180) / 2, dy = sin(angle * .pi / 180) / 2
        let frames = (0 ... steps).map { i -> [[Double]] in
            let distance = from + (to - from) * Double(i) / Double(steps)
            return [[x - dx * distance, y - dy * distance], [x + dx * distance, y + dy * distance]]
        }
        return try gesture(frames)
    }

    /// Inserts text into the app's focused input, as its keyboard would.
    public func type(_ text: String, submit: Bool) throws -> [String: Any] {
        var result = try request("text", ["text": text])
        if submit { result = try key("return") }
        return result
    }

    private static let keys = [
        "return": "return", "enter": "return", "delete": "backspace", "backspace": "backspace",
        "forward-delete": "delete", "tab": "tab", "escape": "escape", "space": "space",
        "up": "up", "down": "down", "left": "left", "right": "right",
    ]

    public func key(_ name: String, count: Int = 1) throws -> [String: Any] {
        guard let key = Self.keys[name.lowercased()] else {
            throw IcliError.failed("a Parallel session accepts the keys \(Self.keys.keys.sorted().joined(separator: ", "))")
        }
        guard (1 ... 100).contains(count) else { throw IcliError.failed("count must be 1–100") }
        var result: [String: Any] = [:]
        for _ in 0 ..< count { result = try request("key", ["key": key]) }
        return result
    }

    // MARK: Capture

    /// The session's scene as an image, in the app's interface orientation,
    /// with the size of that interface in points.
    public func capture() throws -> (image: CGImage, points: CGSize, info: [String: Any]) {
        var info = try request("screenshot")
        guard let path = info.removeValue(forKey: "path") as? String else { throw IcliError.failed("Parallel sent no screenshot") }
        // Read it whole before the file goes: an image source decodes lazily.
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        unlink(path)
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw IcliError.failed("Parallel's screenshot is not a valid image") }
        let width = info["width"] as? Double ?? Double(image.width) / 3
        let height = info["height"] as? Double ?? Double(image.height) / 3
        return (image, CGSize(width: width, height: height), info)
    }

    /// A screenshot file shaped like `screen shot`'s: one pixel per point by
    /// default, `width` pixels wide, or the scene's full pixels.
    public func screenshot(path requestedPath: String?, base64: Bool, nativeResolution: Bool, width: Double?, png: Bool) throws -> [String: Any] {
        let (full, points, info) = try capture()
        if width != nil, nativeResolution { throw IcliError.failed("give --width or --native-resolution, not both") }
        let target = nativeResolution ? Double(full.width) : (width ?? points.width)
        guard target.isFinite, target >= 1, target <= Double(full.width) else {
            throw IcliError.failed("width must be 1–\(full.width) pixels")
        }
        let image = try scaled(full, toWidth: Int(target.rounded()))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, (png ? "public.png" : "public.jpeg") as CFString, 1, nil)
        else { throw IcliError.failed("image encoder unavailable") }
        let options: NSDictionary? = png ? nil : [kCGImageDestinationLossyCompressionQuality as String: 0.8]
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw IcliError.failed("image encoding failed") }
        var result: [String: Any] = [
            "bytes": data.length, "mime_type": png ? "image/png" : "image/jpeg", "width": image.width, "height": image.height,
            "coordinate_scale": Double(image.width) / points.width, "parallel": info,
        ]
        if base64 { result["data"] = (data as Data).base64EncodedString() }
        if !base64 || requestedPath != nil {
            let path = requestedPath
                ?? (JailbreakRoot.current.scratchDirectory() + "/icli-\(UUID().uuidString)." + (png ? "png" : "jpg"))
            try (data as Data).write(to: URL(fileURLWithPath: path))
            result["path"] = path
        }
        return result
    }

    private func scaled(_ image: CGImage, toWidth width: Int) throws -> CGImage {
        guard width != image.width else { return image }
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw IcliError.failed("image scaling failed") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw IcliError.failed("image scaling failed") }
        return result
    }
}
