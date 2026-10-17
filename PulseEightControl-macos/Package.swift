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
    ],
    targets: [
        .executableTarget(
            name: "PulseEightControl",
            dependencies: [
                .product(name: "PulseEightKit", package: "PulseEightKit"),
                .product(name: "PulseEightCore", package: "PulseEightKit"),
            ],
            linkerSettings: [
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
    ]
)
