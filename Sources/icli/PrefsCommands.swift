import ArgumentParser
import Foundation
import IcliKit

struct Prefs: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Read and change preference domains through cfprefsd, like defaults.",
        discussion: "<domain> is a domain such as com.apple.springboard or an absolute path to a .plist file. --user defaults to mobile, even under sudo.",
        subcommands: [Read.self, Write.self, Delete.self],
    )
}

struct PreferenceUserOption: ParsableArguments {
    @Option(help: "Whose preferences: mobile, root, current or any.") var user: String = "mobile"

    func parsed() throws -> PreferenceUser {
        guard let user = PreferenceUser(rawValue: user) else {
            throw IcliError.failed("--user must be mobile, root, current or any")
        }
        return user
    }
}

private let notifyHelp: ArgumentHelp = "Darwin notification to post after the change."

private let appHelp: ArgumentHelp = "Use this app's own preferences file in its data container instead of a domain; --user does not apply."

/// `<domain> rest...`, or with --app just `rest...`.
private func splitDomain(_ arguments: [String], app: String?, keyRange: ClosedRange<Int>, usage: String) throws
    -> (domain: String, rest: [String])
{
    let rest = app == nil ? Array(arguments.dropFirst()) : arguments
    guard app != nil || !arguments.isEmpty, keyRange.contains(rest.count) else {
        throw IcliError.failed("usage: \(usage)")
    }
    return (app == nil ? arguments[0] : "", rest)
}

extension Prefs {
    struct Read: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "One key with its type, or the whole domain as {key: {value, type}}",
        )
        @OptionGroup var output: OutputOptions
        @OptionGroup var user: PreferenceUserOption
        @Option(help: appHelp) var app: String?
        @Argument(help: "<domain> [<key>], or with --app only [<key>].") var arguments: [String] = []
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) {
                let parts = try splitDomain(arguments, app: app, keyRange: 0 ... 1, usage: "prefs read <domain> [<key>] | --app <bundle-id> [<key>]")
                if let app { return try readAppPreference(bundleID: app, key: parts.rest.first) }
                return try readPreference(domain: parts.domain, key: parts.rest.first, user: user.parsed())
            }
        }
    }

    struct Write: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Set one key and return the value read back")
        @OptionGroup var output: OutputOptions
        @OptionGroup var user: PreferenceUserOption
        @Option(help: appHelp) var app: String?
        @Argument(help: "<domain> <key> <value>, or with --app only <key> <value>.") var arguments: [String] = []
        @Option(
            help: "string, int, float, bool, date (ISO-8601 or epoch seconds), data (Base64) or json (array or object).",
        )
        var type: String = "string"
        @Option(help: notifyHelp) var notify: String?
        @Flag(help: "With --app, stop the app if it is running.") var force = false
        func run() {
            emit(allowWhenLocked: true, output) {
                let parts = try splitDomain(arguments, app: app, keyRange: 2 ... 2, usage: "prefs write <domain> <key> <value> | --app <bundle-id> <key> <value>")
                let value = try PreferenceValue(text: parts.rest[1], type: type)
                if let app {
                    guard notify == nil else { throw IcliError.failed("--notify does not apply with --app") }
                    return try writeAppPreference(bundleID: app, key: parts.rest[0], value: value, force: force)
                }
                return try writePreference(
                    domain: parts.domain,
                    key: parts.rest[0],
                    value: value,
                    user: user.parsed(),
                    notify: notify,
                )
            }
        }
    }

    struct Delete: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Remove one key and confirm it is gone")
        @OptionGroup var output: OutputOptions
        @OptionGroup var user: PreferenceUserOption
        @Option(help: appHelp) var app: String?
        @Argument(help: "<domain> <key>, or with --app only <key>.") var arguments: [String] = []
        @Option(help: notifyHelp) var notify: String?
        @Flag(help: "With --app, stop the app if it is running.") var force = false
        func run() {
            emit(allowWhenLocked: true, output) {
                let parts = try splitDomain(arguments, app: app, keyRange: 1 ... 1, usage: "prefs delete <domain> <key> | --app <bundle-id> <key>")
                if let app {
                    guard notify == nil else { throw IcliError.failed("--notify does not apply with --app") }
                    return try deleteAppPreference(bundleID: app, key: parts.rest[0], force: force)
                }
                return try deletePreference(domain: parts.domain, key: parts.rest[0], user: user.parsed(), notify: notify)
            }
        }
    }
}
