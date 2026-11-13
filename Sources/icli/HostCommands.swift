import ArgumentParser
import Foundation
import IcliKit

struct Log: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Capture system logs and read crash reports.",
        subcommands: [Syslog.self, Crashes.self, Crash.self],
    )
}

extension Log {
    struct Syslog: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Capture the live unified log; every filter applies before --max-lines",
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "Seconds to capture, 0.1–60.") var seconds: Double = 3
        @Option(help: "Case-insensitive substring of the process name") var process: String?
        @Option(help: "Process identifier") var pid: Int32?
        @Option(help: "Subsystem, with its dotted children") var subsystem: String?
        @Option(help: "Category, exactly") var category: String?
        @Option(help: "Case-sensitive substring of the message") var messageContains: String?
        @Option(help: "Minimum level: all, debug, info, default, notice, error or fault") var level: String = "all"
        @Option(help: "Most lines returned, 1–5000.") var maxLines: Int = 500
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) {
                try captureSyslog(
                    seconds: seconds,
                    process: process,
                    level: level,
                    maxLines: maxLines,
                    subsystem: subsystem,
                    category: category,
                    messageContains: messageContains,
                    pid: pid,
                )
            }
        }
    }

    struct Crashes: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(help: "Only reports whose file name contains this bundle ID or the app's executable name.") var bundleID: String?
        @Option(help: "Only reports written since: ISO-8601, epoch seconds, or an age such as 30s, 5m or 2h.")
        var since: String?
        @Option(help: "Only reports of one kind, by file name: crash, spin (spins and hangs), diagnostic (jetsam, resource, panic, watchdog…) or log (anything else). Default: every .ips and .crash report.")
        var kind: String?
        @Option(help: "List only the newest N; count still says how many there are, and truncated is true.") var limit: Int?
        func run() {
            emit(requiresLease: false, output) {
                let kind = try kind.map { name -> CrashReportKind in
                    guard let kind = CrashReportKind(rawValue: name) else {
                        throw IcliError.failed("kind must be crash, spin, diagnostic or log")
                    }
                    return kind
                }
                return try crashLogs(bundleID: bundleID, since: since.map(parseCrashCutoff), kind: kind, limit: limit)
            }
        }
    }

    struct Crash: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument(help: "The report's path from log crashes; omit it with --bundle-id.") var path: String?
        @Option(help: "Instead of a path: this app's newest crash report (bundle ID or executable name).") var bundleID: String?
        @Option(help: "Read at most this many bytes; truncated says the report goes on") var maxBytes: Int?
        @Flag(help: "The process, exception, termination and crashed thread's stack instead of the whole report.")
        var summary = false
        func run() {
            emit(requiresLease: false, output) {
                guard !summary || maxBytes == nil else { throw IcliError.failed("--summary reads the whole report; omit --max-bytes") }
                guard (path == nil) != (bundleID == nil) else { throw IcliError.failed("give a path or --bundle-id, not both") }
                var report = path
                if let bundleID {
                    let newest = (try crashLogs(bundleID: bundleID, kind: .crash)["crashes"] as? [String])?.first
                    guard let newest else { throw IcliError.failed("no crash reports for \(bundleID)") }
                    report = newest
                }
                return summary ? try summarizeCrashLog(report!) : try readCrashLog(report!, maxBytes: maxBytes)
            }
        }
    }
}

struct Pkg: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Inspect, install, and remove Debian packages and manage package sources.",
        subcommands: [
            List.self, Install.self, Remove.self, Info.self, Extract.self,
            Status.self, Compare.self, Repos.self, AddRepo.self, Tweaks.self
        ],
    )
}

extension Pkg {
    struct Info: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Control fields, scripts and file list of a .deb",
        )
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try readDeb(path) }
        }
    }

    struct Extract: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Unpack a .deb into an empty directory (DEBIAN/ plus payload)",
        )
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument var destination: String
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try extractDeb(path, to: destination) }
        }
    }

    struct Status: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Installed state and version from dpkg's database")
        @OptionGroup var output: OutputOptions
        @Argument var name: String
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try packageStatus(name) }
        }
    }

    struct Compare: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Compare two Debian version strings")
        @OptionGroup var output: OutputOptions
        @Argument var left: String
        @Argument var right: String
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try compareDebianVersions(left, right) }
        }
    }

    struct List: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(help: "Case-insensitive substring of the package identifier or name.") var filter: String?
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try listPackages(filter: filter) }
        }
    }

    struct Install: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Install a local .deb natively (root); maintainer scripts are reported, not run",
        )
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag(help: "Install even when Depends/Pre-Depends are not satisfied") var ignoreDepends = false
        func run() {
            emit(allowWhenLocked: true, output) { try installDebFile(path, ignoreDependencies: ignoreDepends) }
        }
    }

    struct Remove: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Remove an installed Debian package. Requires root; keeps package configuration files unless --purge is supplied.",
        )
        @OptionGroup var output: OutputOptions
        @Argument var name: String
        @Flag(help: "Also remove the package's configuration files.") var purge = false
        func run() {
            emit(allowWhenLocked: true, output) { try removeDeb(name, purge: purge) }
        }
    }

    struct Repos: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try listRepos() }
        }
    }

    struct AddRepo: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "add-repo")
        @OptionGroup var output: OutputOptions
        @Argument var url: String
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try addRepo(url) }
        }
    }

    struct Tweaks: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try listTweaks() }
        }
    }
}

struct SB: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Refresh app registrations, restart SpringBoard, and manage system app visibility.",
        subcommands: [Uicache.self, Respring.self, SystemApps.self],
    )
}

extension SB {
    struct Uicache: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Refresh app registrations in the bootstrap's /Applications",
        )
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { try refreshApps(directory: nil) }
        }
    }

    struct Respring: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { try respring() }
        }
    }

    struct SystemApps: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "system-apps",
            abstract: "Visibility of non-default system apps",
            subcommands: [Get.self, Set.self],
        )
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            func run() {
                emit(allowWhenLocked: true, requiresLease: false, output) { try systemAppsVisibility(set: nil) }
            }
        }

        struct Set: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument var value: String
            func run() {
                emit(allowWhenLocked: true, output) { try systemAppsVisibility(set: parseOnOff(value)) }
            }
        }
    }
}

struct Account: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Bootstrap user accounts",
        subcommands: [SetPassword.self],
    )
}

extension Account {
    struct SetPassword: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "set-password",
            abstract: "Read the new password from stdin (first line) and store it for the bootstrap account",
        )
        @OptionGroup var output: OutputOptions
        @Argument var user: String = "mobile"
        func run() {
            emit(allowWhenLocked: true, output) {
                guard let line = readLine(strippingNewline: true) else {
                    throw IcliError.failed("no password on stdin")
                }
                return try setAccountPassword(user: user, password: line)
            }
        }
    }
}

struct Env: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Runtime environment and capability report",
        subcommands: [Info.self, Basebin.self],
        defaultSubcommand: Info.self,
    )
}

extension Env {
    struct Info: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try environmentReport() }
        }
    }

    struct Basebin: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Compare the installed BaseBin version with a bundled basebin.tar",
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "Path to a basebin archive containing basebin/.version") var bundled: String?
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try compareBaseBin(bundled: bundled) }
        }
    }
}

struct Proc: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "List running processes.", subcommands: [List.self])
}

extension Proc {
    struct List: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(help: "Case-insensitive substring of the process name.") var filter: String?
        func run() {
            emit(requiresLease: false, output) { try listProcesses(filter: filter) }
        }
    }
}

struct Net: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Capture network traffic to a packet capture file.",
        subcommands: [Capture.self],
    )
}

extension Net {
    struct Capture: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(help: "Seconds to capture, 1–60.") var seconds: Double = 5
        @Option(help: "Network interface, such as en0 (Wi-Fi) or pdp_ip0 (cellular).") var interface: String = "en0"
        @Option(help: "[tcp|udp|icmp] [src|dst] port N [src|dst] host A, joined with and") var filter: String?
        @Option(name: .customLong("output"), help: "pcap path (default: a temporary file)") var path: String?
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) {
                try capturePackets(seconds: seconds, interface: interface, filter: filter, output: path)
            }
        }
    }
}
