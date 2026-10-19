// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PulseEightKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PulseEightKit", targets: ["PulseEightKit"]),
        // Shared app logic (settings, secrets, connection phase, commands). UI-agnostic.
        .library(name: "PulseEightCore", targets: ["PulseEightCore"]),
        // The C interface to the core, for the Windows app: pulseeight_core.dll / libpulseeight_core.dylib.
        .library(name: "pulseeight_core", type: .dynamic, targets: ["PulseEightCoreExports"]),
        .executable(name: "p8ctl", targets: ["p8ctl"]),
    ],
    targets: [
        // Foundation-only device layer. No UI, builds and tests on macOS, Windows and Linux.
        .target(name: "PulseEightKit"),
        .target(name: "PulseEightCore", dependencies: ["PulseEightKit"]),
        .target(name: "PulseEightCoreExports", dependencies: ["PulseEightCore"]),
        .executableTarget(name: "p8ctl", dependencies: ["PulseEightKit", "PulseEightCore"]),
        .testTarget(
            name: "PulseEightKitTests",
            dependencies: ["PulseEightKit"],
            // Responses captured from a real matrix (`p8ctl capture`); see Fixtures/Real/README.md.
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PulseEightCoreTests", dependencies: ["PulseEightCore", "PulseEightKit"]),
        // The C interface called from Swift, as the Windows app calls it from C#.
        .testTarget(name: "PulseEightCoreExportsTests", dependencies: ["PulseEightCoreExports", "PulseEightCore"]),
    ]
)
