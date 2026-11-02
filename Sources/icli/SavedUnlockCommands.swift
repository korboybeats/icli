import ArgumentParser
import Darwin
import IcliKit

struct SavedUnlock: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "Unlock using the passcode saved in this phone's Keychain (root; no prompt).",
        discussion: "Provision once from Windows/WSL with icli-unlock --provision-phone. Then run icli unlock in a root phone terminal. After a restart, manually unlock once before the saved Keychain item becomes available. Existing lockout guards apply; no retries.")
    @OptionGroup var output: OutputOptions
    @Flag(help: "Check access and policy without attempting an unlock.") var check = false
    @Option(help: "Failure ceiling, 1–4.") var maxFailures = defaultPasscodeFailureLimit
    @Flag(help: "Provision from piped stdin; saves without attempting an unlock.") var storeFromStdin = false
    @Flag(help: "Remove this phone's saved passcode; leaves the failure ledger intact.") var forgetStored = false

    func validate() throws {
        guard !(storeFromStdin && forgetStored), !(check && (storeFromStdin || forgetStored)) else {
            throw ValidationError("choose unlock/check, --store-from-stdin, or --forget-stored")
        }
        guard (1 ... passcodeFailureCeiling).contains(maxFailures) else {
            throw ValidationError("--max-failures must be 1–\(passcodeFailureCeiling)")
        }
    }

    func run() {
        emit(allowWhenLocked: true, output) {
            if storeFromStdin {
                guard geteuid() == 0 else { throw IcliError.failed("provisioning requires root") }
                guard isatty(STDIN_FILENO) == 0 else {
                    throw IcliError.failed("provisioning requires piped input; use icli-unlock --provision-phone from Windows/WSL")
                }
                var passcode = try readPasscodeFromStdin()
                return try saveDevicePasscode(&passcode)
            }
            if forgetStored { return try removeSavedDevicePasscode() }
            return try unlockWithSavedPasscode(limit: maxFailures, checkOnly: check)
        }
    }
}
