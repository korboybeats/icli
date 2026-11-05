import ArgumentParser
import Foundation
import IcliKit

struct Screen: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Touch, pointer, screenshot, OCR",
        subcommands: [
            Tap.self, Swipe.self, Pinch.self, LongPress.self, DoubleTap.self, Drag.self, Touch.self,
            TouchSequence.self, Click.self, Scroll.self, ScrollBy.self, Gesture.self, Shot.self, Record.self, Wait.self, Info.self, OCR.self, Describe.self
        ],
    )
}

private let pointHelp: ArgumentHelp = "UI points from the top-left corner, in the orientation shown; see screen info."

private let normalizedHelp: ArgumentHelp =
    "x and y are 0–1 in the fixed portrait digitizer space instead of UI points."

private let pointerNormalizedHelp: ArgumentHelp =
    "x and y are 0–1 of the interface as it is shown instead of UI points."

extension Screen {
    struct Tap: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument(help: pointHelp) var x: Double
        @Argument(help: pointHelp) var y: Double
        @OptionGroup var then: ExpectOptions
        func run() {
            emit(output) { try then.after { try tap(x: x, y: y) } }
        }
    }

    struct Swipe: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(help: "Start x in UI points.") var fromX: Double
        @Option(help: "Start y in UI points.") var fromY: Double
        @Option(help: "End x in UI points.") var toX: Double
        @Option(help: "End y in UI points.") var toY: Double
        @Option(help: "Duration of the movement in seconds, up to 60.") var seconds: Double = 0.25
        @Option(help: "Intermediate move events, 1–2000.") var steps: Int = 20
        @Flag(help: "End with a short slow move, so a scroll view stops when the finger lifts; --steps has no effect and --seconds can only lengthen the stroke.")
        var noMomentum = false
        func run() {
            emit(output) {
                noMomentum
                    ? try swipeWithoutMomentum(x1: fromX, y1: fromY, x2: toX, y2: toY, seconds: seconds, steps: steps)
                    : try swipe(x1: fromX, y1: fromY, x2: toX, y2: toY, seconds: seconds, steps: steps)
            }
        }
    }

    struct ScrollBy: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "scroll-by",
            abstract: "Scroll content an exact distance with touch, without a fling.",
            discussion: "up reveals content above, down content below. A long distance takes several strokes; "
                + "the content stops sooner where it ends. Each stroke starts at --x/--y; by default it runs through "
                + "the middle of the screen, starting 20% in from the edge it moves away from.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "up, down, left or right.") var direction: String
        @Argument(help: "Points the content moves.") var points: Double
        @Option(help: "Where strokes start, x in UI points, in the scroll view.") var x: Double?
        @Option(help: "Where strokes start, y in UI points, in the scroll view.") var y: Double?
        func run() {
            emit(output) { try scrollBy(direction: direction, points: points, x: x, y: y) }
        }
    }

    struct Pinch: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Two-finger pinch: the fingers move from --from to --to points apart (larger --to zooms in).",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: pointHelp) var x: Double
        @Argument(help: pointHelp) var y: Double
        @Option(help: "Starting distance between the fingers in UI points.") var from: Double
        @Option(help: "Final distance between the fingers in UI points.") var to: Double
        @Option(help: "Direction of the line through both fingers in degrees; 0 is horizontal, 90 vertical.") var angle: Double = 0
        @Option(help: "Duration of the movement in seconds, up to 60.") var seconds: Double = 0.4
        @Option(help: "Intermediate move events, 1–2000.") var steps: Int = 20
        func run() {
            emit(output) { try pinch(x: x, y: y, from: from, to: to, angle: angle, seconds: seconds, steps: steps) }
        }
    }

    struct LongPress: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "long-press")
        @OptionGroup var output: OutputOptions
        @Argument(help: pointHelp) var x: Double
        @Argument(help: pointHelp) var y: Double
        @Option(help: "Seconds to hold, up to 60.") var seconds: Double = 0.6
        func run() {
            emit(output) { try longPress(x: x, y: y, seconds: seconds) }
        }
    }

    struct DoubleTap: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "double-tap")
        @OptionGroup var output: OutputOptions
        @Argument(help: pointHelp) var x: Double
        @Argument(help: pointHelp) var y: Double
        @Option(help: "Seconds between the two taps, up to 1.") var interval: Double = 0.1
        func run() {
            emit(output) { try doubleTap(x: x, y: y, interval: interval) }
        }
    }

    struct Drag: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(help: "Start x in UI points.") var fromX: Double?
        @Option(help: "Start y in UI points.") var fromY: Double?
        @Option(help: "End x in UI points.") var toX: Double?
        @Option(help: "End y in UI points.") var toY: Double?
        @Option(
            help: "Drag path as a JSON array of {x,y} points; use this option or all four endpoint options, not both.",
        )
        var points: String?
        @Option(help: "Duration of the movement in seconds, up to 60.") var seconds: Double = 0.3
        @Option(help: "Seconds to press at the first point before moving, as a long-press drag needs; 0 for none.") var hold: Double = 0.5
        @Option(help: "Move events across the whole path, at least one per segment, up to 2000.") var steps: Int = 20
        func run() {
            emit(output) {
                let path: [(Double, Double)]
                if let points {
                    guard fromX == nil, fromY == nil, toX == nil, toY == nil else {
                        throw IcliError.failed("provide points or endpoints, not both")
                    }
                    guard let rows = try JSONSerialization.jsonObject(with: Data(points.utf8)) as? [[String: Double]] else {
                        throw IcliError.failed("points must be a JSON array of {x,y}")
                    }
                    path = try rows.map { row in
                        guard let x = row["x"], let y = row["y"] else {
                            throw IcliError.failed("each point needs x and y")
                        }
                        return (x, y)
                    }
                } else {
                    guard let fromX, let fromY, let toX, let toY else {
                        throw IcliError.failed("provide points or all four endpoint coordinates")
                    }
                    path = [(fromX, fromY), (toX, toY)]
                }
                return try drag(points: path, seconds: seconds, hold: hold, steps: steps)
            }
        }
    }

    struct Touch: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Send one raw digitizer event: down, move or up.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "down, move or up.") var phase: String
        @Argument(help: pointHelp) var x: Double
        @Argument(help: pointHelp) var y: Double
        @Flag(help: normalizedHelp) var normalized = false
        func run() {
            emit(output) {
                guard let phase = TouchPhase(rawValue: phase) else {
                    throw IcliError.failed("phase must be down, move or up")
                }
                return try touch(phase, x: x, y: y, normalized: normalized)
            }
        }
    }

    struct TouchSequence: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "touch-sequence",
            abstract: "Send several digitizer events from one process.",
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "JSON array of {phase,x,y,delay_ms}; delay_ms is the pause after that event.") var events: String
        @Flag(help: normalizedHelp) var normalized = false
        func run() {
            emit(output) { try touchSequence(TouchEvent.list(fromJSON: events), normalized: normalized) }
        }
    }

    struct Click: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Click with a virtual pointer, as a trackpad does on an iPad.",
            discussion: "The pointer exists only while the command runs. iOS on an iPhone uses it only through AssistiveTouch's pointer devices.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: pointHelp) var x: Double
        @Argument(help: pointHelp) var y: Double
        @Option(help: "primary, secondary or middle.") var button = "primary"
        @Option(help: "1 for a click, 2 for a double click, 3 for a triple click.") var count = 1
        @Option(help: "Seconds each press is held.") var hold = 0.05
        @Option(help: "Seconds the pointer rests on x, y before the first press.") var hover = 0.0
        @Flag(help: pointerNormalizedHelp) var normalized = false
        func run() {
            emit(output) {
                try pointerClick(
                    x: x, y: y, normalized: normalized, button: PointerButtons(name: button), count: count, hold: hold,
                    hover: hover,
                )
            }
        }
    }

    struct Scroll: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Scroll the view under a virtual pointer, as a trackpad does on an iPad.",
            discussion: "dx and dy are points with a browser wheel's signs: positive dy goes toward the end of the content. The pointer exists only while the command runs.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: pointHelp) var x: Double
        @Argument(help: pointHelp) var y: Double
        @Option(help: "Horizontal distance in points.") var dx = 0.0
        @Option(help: "Vertical distance in points; positive scrolls toward the end.") var dy = 0.0
        @Option(help: "Duration in seconds.") var seconds = 0.3
        @Option(help: "Scroll events sent.") var steps = 15
        @Flag(help: pointerNormalizedHelp) var normalized = false
        func run() {
            emit(output) {
                try pointerScrollGesture(x: x, y: y, normalized: normalized, dx: dx, dy: dy, seconds: seconds, steps: steps)
            }
        }
    }

    struct Shot: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(name: .customLong("output"), help: "Destination JPEG path; defaults to a temporary file.")
        var path: String?
        @Flag(help: "Include the JPEG as Base64 in the result; keep a file only when --output is supplied.")
        var base64 = false
        @Flag(help: "Full device pixels instead of one pixel per UI point.") var nativeResolution = false
        @Flag(help: "Write the raw JPEG to stdout and nothing else; errors go to stderr as JSON.")
        var stdout = false
        @Flag(help: "Also say whether a prompt only the device's owner may answer is on screen; runs text recognition.")
        var checkPrompt = false
        func run() {
            if stdout {
                writeShotToStdout()
                return
            }
            emit(allowWhenLocked: true, output) {
                var shot = try takeScreenshot(path: path, base64: base64, nativeResolution: nativeResolution)
                if checkPrompt { shot["prompt"] = try currentPrompt() }
                return shot
            }
        }
    }

    struct Record: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Record the screen to a .mov, for --seconds or until SIGINT, SIGTERM or SIGHUP.",
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "Seconds to record, up to 3600; omit it to record until stopped, also up to 3600.") var seconds: Double?
        @Option(name: .customLong("output"), help: "Destination .mov path, replaced if it exists; defaults to a temporary file.")
        var path: String?
        @Option(help: "Frames per second, 1–60.") var fps: Int = 30
        @Option(help: "hevc or h264.") var codec: String = "hevc"
        func run() {
            emit(allowWhenLocked: true, output) { try recordScreen(seconds: seconds, path: path, fps: fps, codec: codec) }
        }
    }

    struct Gesture: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Perform a system gesture.",
            discussion: "spotlight works from the Home Screen. notification-center shows the Cover Sheet, which the device reports as locked until home or `icli unlock` closes it.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "home, app-switcher, control-center, notification-center or spotlight.") var name: String
        func run() {
            emit(allowWhenLocked: name == "home", output) { try systemGesture(name) }
        }
    }

    struct Wait: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Wait until the screen's pixels change, settle, or change and then settle.",
            discussion: """
            Pixels only, so it sees what the accessibility tree does not. A change made before \
            this command starts is invisible to it, so save the screen before the action:

              icli screen shot --output /tmp/before.jpg
              icli ui tap Continue
              icli screen wait --baseline /tmp/before.jpg --changed --stable

            Give --changed, --stable or both. A timeout exits 1 with error timed_out and
            reports whether a change was seen.
            """,
        )
        @OptionGroup var output: OutputOptions
        @Flag(help: "Wait until the screen differs from the baseline.") var changed = false
        @Flag(help: "Wait until the screen stops changing; with --changed, after the change.") var stable = false
        @Option(help: "JPEG from 'screen shot' to compare with; defaults to the screen when this command starts.")
        var baseline: String?
        @Option(help: "Seconds the screen must hold still to count as stable, 0–30.") var stableFor: Double = 0.5
        @Option(help: "Only watch this rectangle, in points: x,y,width,height.") var region: String?
        @Option(help: "Fraction of sampled pixels that must differ to count as a change, 0–1.") var threshold: Double = 0.001
        @Option(help: "Overall deadline in seconds, 0–60.") var timeout: Double = 10
        @Option(help: "Least seconds between captures while the screen keeps changing, 0–5.") var interval: Double = 0.05
        func run() {
            emit(output) {
                try waitForScreen(
                    changed: changed, stable: stable, baseline: baseline, stableFor: stableFor,
                    region: ScreenRegion(text: region), threshold: threshold, timeout: timeout, interval: interval,
                )
            }
        }
    }

    struct Info: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { screenInfo() }
        }
    }

    struct OCR: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(help: "Recognition language; repeat for several.") var lang: [String] = ["zh-Hans", "en-US"]
        @Option(help: "Drop text recognized with less confidence, 0–1.") var minConfidence: Float = 0.3
        @Option(help: "Only read this rectangle, in points: x,y,width,height; quicker than the whole screen.") var region: String?
        @Flag(help: "Quicker, less accurate recognition, for short labels; reads fewer languages (not Chinese).") var fast = false
        @Flag(help: compactHelp) var compact = false
        func run() {
            emit(output, compact: compact) {
                try recognizeScreen(languages: lang, minConfidence: minConfidence, region: ScreenRegion(text: region), fast: fast)
            }
        }
    }

    struct Describe: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try describeScreen() }
        }
    }
}

struct Button: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Hardware buttons",
        subcommands: [Home.self, Power.self, VolumeUp.self, VolumeDown.self, Mute.self, Siri.self, Wake.self],
    )
}

extension Button {
    struct Home: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try pressButton("home") }
        }
    }

    struct Power: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try pressButton("power") }
        }
    }

    struct VolumeUp: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "volume-up")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try pressButton("volume-up") }
        }
    }

    struct VolumeDown: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "volume-down")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try pressButton("volume-down") }
        }
    }

    struct Mute: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try pressButton("mute") }
        }
    }

    struct Siri: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Hold the Siri button for 1.2 s to bring up Siri.")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try pressButton("siri") }
        }
    }

    struct Wake: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { try pressButton("wake") }
        }
    }
}

struct Input: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Text and raw key input",
        subcommands: [Paste.self, TypeText.self, Key.self, HID.self, HideKeyboard.self],
    )
}

extension Input {
    struct HideKeyboard: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "hide-keyboard",
            abstract: "Put the software keyboard away, and wait until it has gone.",
        )
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try hideKeyboard() }
        }
    }

    struct Paste: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument(help: "Text sent in one piece, up to 64 KiB; the clipboard is not used.") var text: String
        @Flag(help: "Empty the focused field first.") var clear = false
        @Flag(help: "Press Return afterwards.") var submit = false
        func run() {
            emit(output) {
                if clear { try clearFocusedField() }
                let result = try pasteText(text)
                if submit { _ = try pressKey("return") }
                return result
            }
        }
    }

    struct TypeText: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "type")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Text sent one character at a time, up to 64 KiB.") var text: String
        @Option(name: .customLong("delay-ms"), help: "Pause after each character in milliseconds, 0–1000.") var delayMS: Double = 30
        @Flag(help: "Empty the focused field first.") var clear = false
        @Flag(help: "Press Return afterwards.") var submit = false
        func run() {
            emit(output) {
                if clear { try clearFocusedField() }
                let result = try typeText(text, delayMS: delayMS)
                if submit { _ = try pressKey("return") }
                return result
            }
        }
    }

    struct Key: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument(help: "return, enter, delete, backspace, forward-delete, tab, escape, space, up, down, left, right, home, end, pageup, pagedown, a letter or a digit, with optional cmd+, ctrl+, shift+, alt+ modifiers.") var name: String
        func run() {
            emit(output) { try pressKey(name) }
        }
    }

    struct HID: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Send a raw HID usage: a press, or only the key going down or up.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "Usage page, decimal or 0x hex: 7 keyboard, 12 (0x0C) consumer.") var page: String
        @Argument(help: "Usage, decimal or 0x hex.") var usage: String
        @Flag(help: "Only press the key down.") var down = false
        @Flag(help: "Only release the key.") var up = false
        func run() {
            emit(output) {
                guard !(down && up) else { throw IcliError.failed("use --down or --up, not both") }
                let page = try parseHIDNumber(page), usage = try parseHIDNumber(usage)
                if down || up {
                    return try hidEvent(page: page, usage: usage, down: down)
                }
                return try hidPress(page: page, usage: usage)
            }
        }
    }
}

struct UI: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Accessibility / OCR elements",
        subcommands: [
            Tree.self, At.self, Tap.self, Back.self, Fill.self, ScrollTo.self, Alert.self, Prompt.self, Perform.self, Wait.self, WaitGone.self
        ],
    )
}

struct ElementSourceOptions: ParsableArguments {
    @Option(help: "Where to look: ax (accessibility tree), ocr (on-screen text recognition; text only, no --identifier or --role) or any (tree, then text). ocr and any report the source used.")
    var source: String = "ax"
    @Option(help: "OCR recognition language; repeat for several.") var lang: [String] = ["zh-Hans", "en-US"]
    func parsed() throws -> ElementSource {
        guard let source = ElementSource(rawValue: source) else {
            throw IcliError.failed("source must be ax, ocr or any")
        }
        return source
    }
}

struct ElementOptions: ParsableArguments {
    @Argument(
        help: "Text to match in an element's label, identifier, or value; required unless --identifier is supplied.",
    )
    var text: String?
    @Option(help: "Match an exact element identifier or label; takes precedence over the text argument.")
    var identifier: String?
    @Option(help: "button, text, control (any tappable element) or element (no filter).") var role: String?
    @Option(help: "Text matching mode: contains or exact; both ignore case.") var match: String = "contains"
    @Option(help: "Zero-based index among all matches. ui tap refuses ambiguous matches unless this is given.") var index: Int?
    func selector() throws -> ElementSelector {
        try ElementSelector(text: text, identifier: identifier, role: role, match: match, index: index)
    }
}

extension UI {
    struct Perform: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Tap once and verify an observed UI transition.")
        @OptionGroup var output: OutputOptions
        @Option(help: "Required verified foreground bundle ID.") var app: String
        @Option(help: "One exact accessibility identifier; ambiguous targets are refused.") var tapIdentifier: String
        @Option(help: "touch (default), or accessibility for direct element activation without touch fallback.") var method: String = "touch"
        @Option(help: "Exact identifier that must be absent before input and appear afterward.") var expectAppeared: String?
        @Option(help: "Exact identifier that must be present before input and disappear afterward.") var expectDisappeared: String?
        @Option(help: "Exact identifier whose AX value must change after input.") var expectValueChanged: String?
        @Option(help: "Overall observation deadline in seconds, 0.1–60; synchronous AX calls may overrun it.") var timeout: Double = 10
        @Option(help: "Least seconds between checks after the tap while the screen keeps changing, 0.1–5.") var interval: Double = 0.1
        @Option(help: "Optional device JPEG path captured on refusal or unconfirmed input.") var failureScreenshot: String?

        func run() {
            // Let the operation enforce lock state itself, retaining a refused
            // outcome rather than losing the action envelope to CLI policy.
            emit(allowWhenLocked: true, output) {
                guard let actionMethod = VerifiedUIActionMethod(rawValue: method) else {
                    throw IcliError.failed("method must be touch or accessibility")
                }
                guard [expectAppeared, expectDisappeared, expectValueChanged].compactMap({ $0 }).count == 1 else {
                    throw IcliError.failed("provide exactly one --expect-appeared, --expect-disappeared or --expect-value-changed")
                }
                let condition: VerifiedUICondition
                if let id = expectAppeared { condition = .appeared(id) }
                else if let id = expectDisappeared { condition = .disappeared(id) }
                else { condition = .valueChanged(expectValueChanged!) }
                return performVerifiedUIAction(VerifiedUIActionRequest(
                    app: app, tapIdentifier: tapIdentifier, condition: condition,
                    timeout: timeout, interval: interval, failureScreenshot: failureScreenshot, method: actionMethod)).payload
            }
        }
    }

    struct Tree: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(help: "Most elements to read from the app, 1–2000; truncated says more exist.") var maxElements: Int = 250
        @Option(help: "Most elements to print after filtering, 1–2000.") var limit: Int?
        @Flag(help: "Include elements outside the visible screen.") var includeOffscreen = false
        @Flag(help: "Only elements that can be tapped.") var clickableOnly = false
        @Option(help: "auto (the app or Home Screen, after anything over it, such as an alert or Control Center), app, system (SpringBoard, status bar included; also reads the Lock Screen) or all.")
        var scope: String = "auto"
        @OptionGroup var from: ElementSourceOptions
        @Flag(help: compactHelp) var compact = false
        func run() {
            emit(allowWhenLocked: scope == "system", output, compact: compact) {
                guard let scope = ElementScope(rawValue: scope) else {
                    throw IcliError.failed("scope must be auto, app, system or all")
                }
                return try screenElements(
                    source: from.parsed(),
                    languages: from.lang,
                    maxElements: maxElements,
                    visibleOnly: !includeOffscreen,
                    clickableOnly: clickableOnly,
                    limit: limit,
                    scope: scope,
                )
            }
        }
    }

    struct At: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument(help: pointHelp) var x: Double
        @Argument(help: pointHelp) var y: Double
        @Flag(help: compactHelp) var compact = false
        func run() {
            emit(output, compact: compact) { try elementAt(x: x, y: y) }
        }
    }

    struct Tap: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @OptionGroup var selection: ElementOptions
        @OptionGroup var from: ElementSourceOptions
        @OptionGroup var then: ExpectOptions
        func run() {
            emit(output) {
                let selector = try selection.selector(), source = try from.parsed()
                return try then.after { try tapElement(selector, source: source, languages: from.lang) }
            }
        }
    }

    struct Back: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Go back: tap the screen's back button, or else swipe in from the left edge.",
            discussion: "method says which. A swipe does nothing on a screen with nowhere to go back to, so check the result.",
        )
        @OptionGroup var output: OutputOptions
        @OptionGroup var then: ExpectOptions
        func run() {
            emit(output) { try then.after { try goBack() } }
        }
    }

    struct Prompt: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Say whether a prompt only the device's owner may answer is on screen.",
            discussion: "Passcode, Face ID, Touch ID, Apple Account, Allow Paste, VPN, profile and purchase prompts. By default the accessibility trees are read and then the screen's text.",
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "ax (trees only, faster), ocr or any.") var source: String = "any"
        func run() {
            emit(allowWhenLocked: true, output) {
                guard let source = ElementSource(rawValue: source) else {
                    throw IcliError.failed("source must be ax, ocr or any")
                }
                return try currentPrompt(source: source)
            }
        }
    }

    struct Fill: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Replace a text field's text: tap the field, empty it, then enter the new text.",
        )
        @OptionGroup var output: OutputOptions
        @OptionGroup var selection: ElementOptions
        @OptionGroup var from: ElementSourceOptions
        @Option(help: "The field's new text; omit it to only empty the field.") var value: String?
        @Flag(help: "Press Return afterwards.") var submit = false
        @OptionGroup var then: ExpectOptions
        func run() {
            emit(output) {
                let selector = try selection.selector(), source = try from.parsed()
                return try then.after {
                    try fillField(selector, value: value, submit: submit, source: source, languages: from.lang)
                }
            }
        }
    }

    struct ScrollTo: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "scroll-to",
            abstract: "Scroll until an element is on screen and say where it is; stops at the end of the content.",
            discussion: "Pages with accessibility where the scroll view allows it, else uses touch strokes; method in "
                + "the result says which. A found element whose tap point is clipped is scrolled into view first.",
        )
        @OptionGroup var output: OutputOptions
        @OptionGroup var selection: ElementOptions
        @OptionGroup var from: ElementSourceOptions
        @Option(help: "up, down, left or right.") var direction: String = "down"
        @Option(help: "Most scrolls before giving up, 1–100.") var maxScrolls: Int = 10
        @Option(help: "A point in the scroll view, x in UI points; default: the middle of the screen.") var x: Double?
        @Option(help: "A point in the scroll view, y in UI points; default: the middle of the screen.") var y: Double?
        func run() {
            emit(output) {
                try scrollToElement(
                    selection.selector(), direction: direction, maxScrolls: maxScrolls, x: x, y: y,
                    source: from.parsed(), languages: from.lang,
                )
            }
        }
    }

    struct Alert: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Answer the alert on screen: accept taps its allowing button, dismiss its refusing one.",
            discussion: "Refuses passcode, Face ID, Touch ID, Apple Account, Allow Paste, VPN, profile and purchase prompts.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "accept or dismiss; omit it with --button.") var action: String?
        @Option(help: "The button's text, instead of an action.") var button: String?
        @OptionGroup var then: ExpectOptions
        func run() {
            emit(output) { try then.after { try answerAlert(action: action, button: button) } }
        }
    }

    struct Wait: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @OptionGroup var selection: ElementOptions
        @OptionGroup var from: ElementSourceOptions
        @Option(help: "Seconds to wait, 0–60; a timeout exits 1.") var timeout: Double = 10
        @Option(help: "Least seconds between checks while the screen keeps changing, 0.1–5; a still screen is not checked again. An OCR check itself takes longer.") var interval: Double = 0.1
        @Flag(help: compactHelp) var compact = false
        func run() {
            emit(output, compact: compact) {
                try waitForElement(
                    selection.selector(), appear: true, timeout: timeout, interval: interval,
                    source: from.parsed(), languages: from.lang,
                )
            }
        }
    }

    struct WaitGone: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "wait-gone")
        @OptionGroup var output: OutputOptions
        @OptionGroup var selection: ElementOptions
        @OptionGroup var from: ElementSourceOptions
        @Option(help: "Seconds to wait, 0–60; a timeout exits 1.") var timeout: Double = 10
        @Option(help: "Least seconds between checks while the screen keeps changing, 0.1–5; a still screen is not checked again. An OCR check itself takes longer.") var interval: Double = 0.1
        @Flag(help: compactHelp) var compact = false
        func run() {
            emit(output, compact: compact) {
                try waitForElement(
                    selection.selector(), appear: false, timeout: timeout, interval: interval,
                    source: from.parsed(), languages: from.lang,
                )
            }
        }
    }
}

private func writeShotToStdout() {
    do {
        // JSON on stdout would corrupt the image a caller is piping to a file.
        guard !Envelope.capturing else { throw IcliError.failed("--stdout cannot run inside a batch or session") }
        try Envelope.applyLockPolicy(allowWhenLocked: true)
        try FileHandle.standardOutput.write(contentsOf: screenshotJPEGData())
    } catch {
        let payload = (error as? IcliError)?.payload ?? IcliError.failed(error.localizedDescription).payload
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        FileHandle.standardError.write(data + Data("\n".utf8))
        Darwin.exit(1)
    }
}

private func parseHIDNumber(_ text: String) throws -> Int {
    let lower = text.lowercased()
    let value = lower.hasPrefix("0x") ? Int(lower.dropFirst(2), radix: 16) : Int(lower)
    guard let value else { throw IcliError.failed("\(text) is not a decimal or 0x hex number") }
    return value
}
