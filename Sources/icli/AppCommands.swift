import ArgumentParser
import Foundation
import IcliKit

extension AppRegistrationType: ExpressibleByArgument {}

struct App: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Installed apps",
        subcommands: [
            List.self, Search.self, Running.self, Frontmost.self, Info.self,
            Launch.self, Relaunch.self, Open.self, Kill.self, Install.self, Uninstall.self,
            Register.self, Unregister.self, Refresh.self, UnregisterDir.self, Network.self,
            Handlers.self, Schemes.self, Binary.self, Data.self, Permission.self, Reset.self, SettingsPage.self,
        ],
    )
}

extension App {
    struct Refresh: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Register new, moved, changed or incompletely registered apps, skip unchanged apps, and drop stale registrations",
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "Directory of .app bundles (default: the bootstrap's /Applications)") var directory: String?
        func run() {
            emit(allowWhenLocked: true, output) { try refreshApps(directory: directory) }
        }
    }

    struct UnregisterDir: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "unregister-dir",
            abstract: "Unregister every registered app whose bundle is directly inside a directory",
        )
        @OptionGroup var output: OutputOptions
        @Argument var directory: String
        @Flag var force = false
        func run() {
            emit(allowWhenLocked: true, output) { try unregisterAppsInDirectory(directory, force: force) }
        }
    }

    struct Network: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Per-app Wi-Fi/cellular data policy",
            subcommands: [Get.self, Repair.self],
        )
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument var bundleID: String
            func run() {
                emit(allowWhenLocked: true, output) { try appNetworkPolicy(bundleID, repair: false) }
            }
        }

        struct Repair: ParsableCommand {
            static var configuration = CommandConfiguration(
                abstract: "Set both policies to always-allow and read them back",
            )
            @OptionGroup var output: OutputOptions
            @Argument var bundleID: String
            func run() {
                emit(allowWhenLocked: true, output) { try appNetworkPolicy(bundleID, repair: true) }
            }
        }
    }

    struct List: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Flag(help: "Only apps whose LaunchServices type is User (installed by the user), not System or the bootstrap's.")
        var user = false
        func run() {
            emit(output) {
                var result = try listApps()
                if user {
                    let apps = (result["apps"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "User" }
                    result["apps"] = apps
                    result["count"] = apps.count
                }
                return result
            }
        }
    }

    struct Search: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var query: String
        func run() {
            emit(output) { try searchApps(query) }
        }
    }

    struct Running: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try runningApps() }
        }
    }

    struct Frontmost: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) {
                var app = frontmostApp()
                if let id = app["bundle_id"] as? String, let name = appDisplayName(id) { app["name"] = name }
                return app
            }
        }
    }

    struct Info: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() {
            emit(output) { try appInfo(bundleID) }
        }
    }

    struct Launch: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument(help: "Bundle ID, or an installed app's display name when only one app has it.") var app: String
        @Flag(help: "Return only once RunningBoard verifies the app in front, with its PID.") var waitForeground = false
        @Option(help: "Seconds --wait-foreground waits, 0–60.") var timeout: Double = 15
        @Option(name: .customLong("arg"), help: "Launch argument for this launch, repeatable; write a dash value as --arg=-Flag. Stops a running app.")
        var arguments: [String] = []
        @Option(name: .customLong("env"), help: "NAME=VALUE environment variable for this launch, repeatable. Stops a running app.")
        var environment: [String] = []
        @Option(help: "Run in this language for this launch, such as fr or pt-BR. Stops a running app.") var language: String?
        @Option(help: "Use this region format for this launch, such as fr_FR. Stops a running app.") var locale: String?
        @Flag(help: "Inject icli's probe agent, so 'icli probe --app <app>' can run scripts inside this launch. Stops a running app.")
        var probe = false
        func run() {
            emit(output) {
                let bundleID = try resolveAppName(app)
                let env = probe ? try environmentWithProbeAgent(environment, bundleID: bundleID) : environment
                if !arguments.isEmpty || !env.isEmpty || language != nil || locale != nil {
                    return try launchAppWithOptions(
                        bundleID, arguments: arguments, environment: env, language: language, locale: locale,
                        waitForeground: waitForeground, timeout: timeout,
                    )
                }
                return waitForeground ? try launchAppVerified(bundleID, timeout: timeout) : try launchApp(bundleID)
            }
        }
    }

    struct Relaunch: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Stop an app, start it, and verify a new process is in front.",
            discussion: "Reports the old PIDs, the new PID, and launched_at for 'log crashes --since'.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "Bundle ID, or an installed app's display name when only one app has it.") var app: String
        @Option(help: "Seconds to wait for the verified foreground app, 0–60.") var timeout: Double = 15
        func run() {
            emit(output) { try relaunchApp(resolveAppName(app), timeout: timeout) }
        }
    }

    struct Open: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var url: String
        @Option(help: "Open the URL in this app instead of the URL's default handler.") var bundle: String?
        func run() {
            emit(output) { try openAppURL(url, bundleID: bundle) }
        }
    }

    struct Kill: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        @Flag var force = false
        func run() {
            emit(output) { try killApp(bundleID, force: force) }
        }
    }

    struct Install: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Install a .deb, an .ipa or a .app bundle",
            discussion: "An .ipa goes into the bootstrap's /Applications, or with --container into its own app container under /var/containers/Bundle/Application with a data container, like an App Store app. icli does not re-sign the app, so the IPA must already be signed so that this device can run it.",
        )
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag(help: "Install the .ipa into its own app container; reinstalling an app icli installed this way upgrades it in place.")
        var container = false
        @Option(help: "How LaunchServices lists a --container app: user or system (default: user).")
        var registration: AppRegistrationType?
        func run() {
            emit(output) {
                guard container || registration == nil else {
                    throw IcliError.failed("--registration applies only with --container")
                }
                return try installPackage(path, container: container, registration: registration ?? .user)
            }
        }
    }

    struct Uninstall: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        @Flag(help: "Required. Removes an app icli installed from an IPA, including its app and data containers for a --container install.")
        var force = false
        @Flag(help: "Treat <bundle-id> as an installed Debian package identifier and remove that package; requires --force.")
        var package = false
        func run() {
            emit(output) {
                if package {
                    guard force else { throw IcliError.forceRequired("uninstall package \(bundleID)") }
                    return try removeDeb(bundleID)
                }
                return try uninstallApp(bundleID, force: force)
            }
        }
    }

    struct Register: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() {
            emit(allowWhenLocked: true, output) { try registerApp(path) }
        }
    }

    struct Unregister: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag var force = false
        func run() {
            emit(allowWhenLocked: true, output) { try unregisterApp(path, force: force) }
        }
    }

    struct Handlers: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var urlOrScheme: String
        func run() {
            emit(output) { try appHandlers(urlOrScheme) }
        }
    }

    struct Schemes: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try appURLSchemes() }
        }
    }

    struct Binary: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() {
            emit(output) { try appBinaryInfo(bundleID) }
        }
    }

    struct Data: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() {
            emit(output) { try appDataDir(bundleID) }
        }
    }
}

struct Clipboard: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Read or replace the clipboard's text or image.",
        subcommands: [Get.self, Set.self],
    )
}

extension Clipboard {
    struct Get: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Text, change count, types, and the image's pixel size if there is one",
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "Write the clipboard image to this path as PNG.") var imageOutput: String?
        func run() {
            emit(output) { try clipboardInfo(imageOutput: imageOutput) }
        }
    }

    struct Set: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Replace the clipboard with text or an image and read it back",
        )
        @OptionGroup var output: OutputOptions
        @Argument var text: String?
        @Option(help: "PNG, JPEG or HEIC file to copy instead of text.") var image: String?
        func run() {
            emit(output) {
                switch (text, image) {
                case (let text?, nil): return try setClipboard(text)
                case (nil, let image?):
                    return try setClipboardImage(Data(contentsOf: URL(fileURLWithPath: image)))
                default: throw IcliError.failed("pass either text or --image")
                }
            }
        }
    }
}

struct URLCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "url",
        abstract: "Open a URL in its registered app.",
        subcommands: [Open.self],
    )
}

extension App {
    struct SettingsPage: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "settings",
            abstract: "Open Settings at an app's own page (permissions, notifications, its settings) and confirm it is shown.",
            discussion: "Fails with no_settings_page when Settings has none for the app: iOS lists only apps with something to set there. System pages open with url open 'prefs:root=<page>'.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "Bundle ID, or an installed app's display name.") var app: String
        @Option(help: "Seconds to wait for the page, 0–60.") var timeout: Double = 5
        func run() {
            emit(output) { try openAppSettings(resolveAppName(app), timeout: timeout) }
        }
    }
}

extension URLCommand {
    struct Open: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var url: String
        @Flag(help: "Afterwards, wait until the screen changes; screen_changed says whether it did (false is not a failure).")
        var checkChanged = false
        @Option(help: "Seconds --check-changed waits, 0–60.") var timeout: Double = 5
        func run() {
            emit(output) { checkChanged ? try openURL(url, checkingChangeFor: timeout) : try openURL(url) }
        }
    }
}

extension App {
    struct Permission: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Read, grant, deny or reset an app's privacy permissions without the system prompt.",
            discussion: "Permissions: \(permissionNames.joined(separator: ", ")). location grants While Using, location-always Always. A reset returns a permission to never asked, so the app's next request shows the system prompt again. iOS stops a running app when any of its permissions change, as Settings does, so launch it afterwards.",
            subcommands: [Get.self, Grant.self, Deny.self, ResetCommand.self],
        )
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument(help: "Bundle ID, or an installed app's display name.") var app: String
            func run() {
                emit(allowWhenLocked: true, output) { try appPermissions(resolveAppName(app)) }
            }
        }
        struct Grant: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument(help: "Bundle ID, or an installed app's display name.") var app: String
            @Argument(help: "One or more permissions.") var permissions: [String]
            func run() {
                emit(allowWhenLocked: true, output) { try setAppPermissions(resolveAppName(app), permissions, action: "grant") }
            }
        }
        struct Deny: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument(help: "Bundle ID, or an installed app's display name.") var app: String
            @Argument(help: "One or more permissions.") var permissions: [String]
            func run() {
                emit(allowWhenLocked: true, output) { try setAppPermissions(resolveAppName(app), permissions, action: "deny") }
            }
        }
        struct ResetCommand: ParsableCommand {
            static var configuration = CommandConfiguration(commandName: "reset")
            @OptionGroup var output: OutputOptions
            @Argument(help: "Bundle ID, or an installed app's display name.") var app: String
            @Argument(help: "Permissions to reset; none resets all.") var permissions: [String] = []
            func run() {
                emit(allowWhenLocked: true, output) { try setAppPermissions(resolveAppName(app), permissions, action: "reset") }
            }
        }
    }

    struct Reset: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Erase an app's data as a fresh install has it, and reset its permissions.",
            discussion: "Stops the app, empties Documents, Library, tmp and SystemData in its data container, and clears its preferences through cfprefsd so no cached value survives. Keychain items and app group containers stay, as they do when an app is deleted.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "Bundle ID, or an installed app's display name.") var app: String
        @Flag(help: "Keep the app's permissions.") var keepPermissions = false
        @Flag(help: "Confirm erasing the app's data; required.") var force = false
        func run() {
            emit(allowWhenLocked: true, output) { try resetApp(resolveAppName(app), force: force, keepPermissions: keepPermissions) }
        }
    }
}
