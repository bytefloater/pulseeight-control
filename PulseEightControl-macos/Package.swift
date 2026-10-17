// swift-tools-version:5.10
import PackageDescription

// The macOS app, in SwiftUI. Its logic lives in ../PulseEightKit (PulseEightKit for the device,
// PulseEightCore for settings, connection and commands), shared with the Windows app; this package is
// only the macOS UI. It is a separate package from ../PulseEightKit so `swift test` on the shared code
// stays UI-free.
let package = Package(
    name: "PulseEightControlApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../PulseEightKit"),
        // Automatic updates (macOS only; Windows has its own updater). Pinned exactly: an update framework
        // is code that replaces the app, so it only moves when someone chooses to.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        // Test-only: the in-process fake matrix the model tests run against.
        .package(path: "../PulseEightFakeServer"),
    ],
    targets: [
        .executableTarget(
            name: "PulseEightControl",
            dependencies: [
                .product(name: "PulseEightKit", package: "PulseEightKit"),
                .product(name: "PulseEightCore", package: "PulseEightKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // Where the packaged .app keeps Sparkle.framework (package.sh and Xcode both put it there).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                // SwiftPM stamps the Mach-O SDK version with the deployment target (macOS 14), and
                // macOS then runs the app in its pre-macOS-26 look. Keep the macOS 14 minimum but
                // declare the newer SDK so the system applies Liquid Glass.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"]),
                // An unbundled executable has no bundle identifier, so AppKit logs errors about App
                // Intents (linkd) and window-tab indexing, and the menu bar shows the process
                // name. Embedding an Info.plist in the binary supplies the identity until the app
                // is packaged properly.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"]),
            ]
        ),
        // The model and its flows, against an in-process fake matrix (no UI is created).
        .testTarget(
            name: "PulseEightControlTests",
            dependencies: [
                "PulseEightControl",
                .product(name: "PulseEightKit", package: "PulseEightKit"),
                .product(name: "PulseEightCore", package: "PulseEightKit"),
                .product(name: "PulseEightFakeMatrix", package: "PulseEightFakeServer"),
            ]
        ),
    ]
)
