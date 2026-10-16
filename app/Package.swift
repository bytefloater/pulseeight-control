// swift-tools-version:5.10
import PackageDescription

// The app is a separate package from ../swift so that `swift test` on PulseEightKit never
// pulls in SwiftCrossUI (and its per-OS backend dependencies).
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
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                // For embedding AppKit views (rotated grid labels) on macOS only.
                .product(name: "AppKitBackend", package: "swift-cross-ui", condition: .when(platforms: [.macOS])),
                .product(name: "PulseEightKit", package: "swift"),
            ],
            linkerSettings: [
                // SwiftPM stamps the Mach-O SDK version with the deployment target (macOS 14),
                // and macOS then runs the app in its pre-macOS-26 look. Keep the macOS 14
                // minimum (SwiftCrossUI's @Observable needs it) but declare the newer SDK so the
                // system applies Liquid Glass.
                .unsafeFlags(
                    ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
    ]
)
