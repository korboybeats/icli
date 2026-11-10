import ArgumentParser
import Foundation
import IcliKit

struct Cc: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Control Center toggles: read, set or flip them",
        discussion: """
        Toggles: \(controlCenterToggles.joined(separator: ", ")).
        Values: on or off; airdrop takes off, contacts or everyone (Everyone turns itself off after 10 minutes); \
        focus takes on (Do Not Disturb), off or a Focus name such as sleep or work; flashlight takes on, off or a \
        level from 0 to 1; appearance takes light or dark. mirroring is read-only.
        Every command answers with the state read back after the change.

        Examples:
          icli cc list
          icli cc set wifi off
          icli cc set airdrop everyone
          icli cc set focus sleep
          icli cc toggle flashlight
        """,
        subcommands: [List.self, Get.self, Set.self, Toggle.self],
    )
}

extension Cc {
    struct List: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Every toggle with its state")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { controlCenterList() }
        }
    }

    struct Get: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "One toggle's state")
        @OptionGroup var output: OutputOptions
        @Argument(help: "The toggle, for example wifi or focus.") var toggle: String
        func run() {
            emit(allowWhenLocked: true, output) { try controlCenterGet(toggle) }
        }
    }

    struct Set: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Set a toggle and read it back")
        @OptionGroup var output: OutputOptions
        @Argument(help: "The toggle, for example wifi or focus.") var toggle: String
        @Argument(help: "on or off, or the toggle's own value (see 'icli cc --help').") var value: String
        func run() {
            emit(allowWhenLocked: true, output) { try controlCenterSet(toggle, value) }
        }
    }

    struct Toggle: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Flip a toggle",
            discussion: "AirDrop flips between off and contacts, focus between off and Do Not Disturb, appearance between light and dark.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "The toggle, for example bluetooth.") var toggle: String
        func run() {
            emit(allowWhenLocked: true, output) { try controlCenterToggle(toggle) }
        }
    }
}
