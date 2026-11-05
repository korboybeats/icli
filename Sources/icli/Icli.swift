import ArgumentParser
import Foundation
import IcliKit

struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Human-readable text instead of JSON")
    var human = false

    func apply() {
        Envelope.human = human
    }
}

/// --compact on the commands that list elements or text blocks: one line each instead of JSON.
let compactHelp = ArgumentHelp(
    "One line per element instead of JSON, for reading the screen in few tokens (wins over --human).",
    discussion: "First line: count, truncated, system_overlay, source and the other result fields as key=value. "
        + "Then per element: [role] [\"label\"] x,y WxH [id=\"…\"] [value=…] [conf=…] [match=x,y] [scope=…] "
        + "[clickable] [disabled] [offscreen]. x,y is the tap point and WxH the frame size, in whole points; "
        + "strings are JSON string literals; empty fields are left out.",
)

func emit(
    allowWhenLocked: Bool = false, _ output: OutputOptions, compact: Bool = false,
    _ body: () throws -> [String: Any],
) {
    output.apply()
    Envelope.compact = compact
    Envelope.run(allowWhenLocked: allowWhenLocked, body)
}

@main
struct Icli: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "icli",
        abstract: "On-device iOS control CLI",
        discussion: "Run 'icli <command> --help' to see its subcommands and 'icli <command> <subcommand> --help' for arguments and options.\n\nExamples:\n  icli device info\n  icli svc list --human\n  icli svc status com.example.service\n\nCommands return JSON by default. Add --human to an action command for readable text, or --compact to ui tree, ui at, ui wait, ui wait-gone and screen ocr for one line per element.",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        subcommands: [
            LockScreenCommand.self, SavedUnlock.self, Device.self, Screen.self, Button.self, Input.self, App.self,
            UI.self, Clipboard.self, FS.self, Log.self, URLCommand.self,
            Pkg.self, SB.self, Svc.self, Account.self, Env.self,
            Proc.self, Sec.self, Net.self, Prefs.self, Location.self, Notify.self, Probe.self, Tests.self, Batch.self,
            Session.self, Status.self, LeaseCommand.self,
        ],
    )
}
