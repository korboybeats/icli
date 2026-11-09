# Third-Party Notices

Swift Package Manager resolves Swift Argument Parser 1.3.1 or later from
https://github.com/apple/swift-argument-parser. Its Apache-2.0 license with
Swift Runtime Library Exception is preserved in
`Resources/Licenses/swift-argument-parser.txt`.

The ArchiveKit 1.0.0 or later Swift package is resolved from
https://github.com/Lakr233/libarchive.xcframework. Its static XCFramework is
linked into icli; no separate libarchive executable or dynamic framework is
shipped. The package's MIT license and notices for libarchive, xz, zstd, and
lz4 are preserved in `Resources/Licenses/libarchive.txt`.

The AX numeric attribute mapping, HID protocol references and unified-log API
integration were informed by witchan/ios-mcp, commit
8f46b68ae6d9cb783cfa55d7a38e6b0afeccf5dd (MIT).
The copyright and license are preserved in `Resources/Licenses/ios-mcp.txt`.
Source: https://github.com/witchan/ios-mcp

Runtime bootstrap API contracts are documented by opa334/libroot and
roothide/libroothide. icli resolves device-provided implementations at runtime.
OCR uses Apple's system Vision framework.

The project license and these dependency notices are included in both DEB packages.

The iOS packages ship a private FLEX 4.7.0 runtime, sourced from the supplied
FlexUltra.zip vendored FLEX tree, upstream commit
`ac50a6d36b738a15a6d3b6b51683d8a152319f59`. Source and provenance are preserved
in `Vendor/FLEX`; its license is included in `Resources/Licenses/FLEX.txt`.
The app agent loads this runtime on explicit inspection requests.

The complete FlexUltra command parser, MCP server, native handlers and shared
protocol are adapted from the user-supplied FlexUltra.zip in `Vendor/FlexUltra`.
The archived originals are preserved there. `scripts/prepare-flexultra.py`
creates the namespaced derivatives and replaces the original transport with
icli's on-demand private Unix socket. No resident FlexUltra broker or injection
tweak is installed. The supplied archive includes no separate top-level
FlexUltra license; its original source headers and dependency notices are retained.

The native tracing engine includes ObjSee (Apache-2.0) and yyjson (MIT), with
licenses in `Resources/Licenses/ObjSee.txt` and `yyjson.txt`. The Swift metadata
library includes Echo and the metadata inspector from Reflex (MIT), with
licenses in `Resources/Licenses/Echo.txt` and `Reflex.txt`. Live Swift value
inspection and mirror construction are disabled in the supplied implementation
and remain disabled here. Generated derivative files identify icli's changes.
