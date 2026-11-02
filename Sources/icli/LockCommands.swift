import ArgumentParser
import IcliKit

struct LockScreenCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Lock the phone and turn off its screen; already locked/screen-off is a no-op.",
        discussion: "Sends the power-button action once only when the screen is on, then checks for locked and screen-off for up to three seconds. Exit 0 confirms both; exit 3 means input was sent but that state was not confirmed. No automatic retry. Use icli unlock to unlock with the saved phone Keychain credential.")
    @OptionGroup var output: OutputOptions
    func run() {
        emit(allowWhenLocked: true, output) { try lockDevice() }
    }
}
