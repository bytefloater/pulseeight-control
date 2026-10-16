// swift-tools-version:5.10
import PackageDescription

// The app is a separate package from ../swift so that `swift test` on PulseEightKit never
// pulls in SwiftCrossUI (and its per-OS backend dependencies).
//
// macOS-only pieces are chosen with `#if os(macOS)` (the manifest is compiled for the host)
// rather than with `.when(platforms:)` conditions: SwiftPM's newer build system ignores
// non-Apple platform conditions and would try to build AppKit code on Windows.
//
// On Windows set SCUI_DEFAULT_BACKEND=WinUIBackend before building, for the same reason:
// SwiftCrossUI's DefaultBackend lists the WinUI and GTK backends behind platform conditions,
// and the GTK one would otherwise be compiled (and fail without GTK installed).

var appDependencies: [Target.Dependency] = [
    .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
    .product(name: "DefaultBackend", package: "swift-cross-ui"),
    .product(name: "PulseEightKit", package: "swift"),
]
var appLinkerSettings: [LinkerSetting] = []

#if os(macOS)
    // For embedding AppKit views (rotated grid labels) on macOS only.
    appDependencies.append(.product(name: "AppKitBackend", package: "swift-cross-ui"))
    appLinkerSettings += [
        // SwiftPM stamps the Mach-O SDK version with the deployment target (macOS 14), and macOS
        // then runs the app in its pre-macOS-26 look. Keep the macOS 14 minimum (SwiftCrossUI's
        // @Observable needs it) but declare the newer SDK so the system applies Liquid Glass.
        .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"]),
        // An unbundled executable has no bundle identifier, so AppKit logs errors about App
        // Intents (linkd) and window-tab indexing, and the menu bar shows the process name.
        // Embedding an Info.plist in the binary supplies the identity until the app is packaged
        // properly (Swift Bundler, M6).
        .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"]),
    ]
#endif

let package = Package(
    name: "PulseEightControlApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", .upToNextMinor(from: "0.10.0")),
        .package(path: "../swift"),
    ],
    targets: [
        .executableTarget(
            name: "PulseEightControl",
            dependencies: appDependencies,
            linkerSettings: appLinkerSettings
        ),
    ]
)
