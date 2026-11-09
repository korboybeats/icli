import ArgumentParser
import Darwin
import Foundation
import IcliKit

struct Flex: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "FlexUltra's full command set through icli's on-demand app agent.",
        discussion: "icli flex --help lists the imported commands. Use --target <bundle-id|PID|process>. 'icli flex mcp' serves the same tools over stdin/stdout; 'icli flex catalog' lists every operation.")

    @Argument(parsing: .captureForPassthrough, help: "FlexUltra command and options")
    var arguments: [String] = []

    func run() throws {
        do { try Envelope.applyLockPolicy(allowWhenLocked: true) }
        catch {
            Envelope.run(allowWhenLocked: true) { throw error }
            return
        }
        let router = FlexUltraRouter { argv in
            let step = try BatchStep(row: argv, index: 0)
            return step.execute()
        }
        Darwin.exit(runFlexUltra(arguments, request: router.handle))
    }
}
