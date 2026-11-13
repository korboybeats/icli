import ArgumentParser
import Foundation
import IcliKit

struct Cc: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Control Center toggles and audio outputs",
        discussion: """
        Toggles: \(controlCenterToggles.joined(separator: ", ")).
        Values: on or off; airdrop takes off, contacts or everyone (Everyone turns itself off after 10 minutes); \
        focus takes on (Do Not Disturb), off or a Focus name such as sleep or work; flashlight takes on, off or a \
        level from 0 to 1; appearance takes light or dark. mirroring is read-only.
        Every command answers with the state read back after the change.
        Audio outputs: 'audio list' lists names and exact UIDs; 'audio select <route-uid>' waits for verified selection.

        Examples:
          icli cc list
          icli cc set wifi off
          icli cc set airdrop everyone
          icli cc set focus sleep
          icli cc toggle flashlight
          icli cc audio list
        """,
        subcommands: [List.self, Get.self, Set.self, Toggle.self, Audio.self],
    )
}

extension Cc {
    struct Audio: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "List or select the system audio output",
            discussion: "Uses Audio/Video outputs discovered from the native audio service. Selection waits for the exact UID to read back as selected. Volume is left to the system's existing per-output settings.",
            subcommands: [List.self, Select.self],
        )

        struct List: ParsableCommand {
            static var configuration = CommandConfiguration(abstract: "Available audio outputs with names, UIDs and selected state")
            @OptionGroup var output: OutputOptions
            func run() {
                emit(allowWhenLocked: true, output) { try controlCenterAudioList() }
            }
        }

        struct Select: ParsableCommand {
            static var configuration = CommandConfiguration(abstract: "Select an exact route UID and verify the selected output")
            @OptionGroup var output: OutputOptions
            @Argument(help: "Exact, case-sensitive UID from 'icli cc audio list'.") var routeUid: String
            @Option(help: "Seconds to wait for native confirmation, greater than 0 and at most 60.") var timeout: Double = 8
            func validate() throws {
                guard !routeUid.isEmpty, !routeUid.utf8.contains(0) else {
                    throw ValidationError("route-uid must be nonempty and contain no NUL bytes")
                }
                guard timeout.isFinite, timeout > 0, timeout <= 60 else {
                    throw ValidationError("timeout must be greater than 0 and at most 60 seconds")
                }
            }
            func run() {
                emit(allowWhenLocked: true, output) { try controlCenterAudioSelect(routeUid, timeout: timeout) }
            }
        }
    }

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
