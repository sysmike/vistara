// swift-tools-version: 6.0
import PackageDescription

// FreeRDP is built by scripts/build-freerdp.sh into this prefix. The paths
// must be absolute because Xcode and `swift build` use different working
// directories.
let freeRDPPrefix = Context.packageDirectory + "/../../build/freerdp/prefix"

let package = Package(
    name: "RDPKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RDPKit", targets: ["RDPKit"]),
        .library(name: "RDPKitUI", targets: ["RDPKitUI"])
    ],
    targets: [
        // C shim over FreeRDP. Its public header exposes no FreeRDP types, so
        // the FreeRDP headers are needed only to compile the shim itself.
        .target(
            name: "CFreeRDP",
            cSettings: [
                .unsafeFlags([
                    "-I\(freeRDPPrefix)/include/freerdp3",
                    "-I\(freeRDPPrefix)/include/winpr3"
                ])
            ],
            // FreeRDP, WinPR, and OpenSSL, linked statically: the app carries
            // no libraries for library validation to refuse (docs/RELEASING.md).
            // What they use of the system follows.
            linkerSettings: [
                .unsafeFlags(["-L\(freeRDPPrefix)/lib"]),
                .linkedLibrary("vistara-freerdp"),
                .linkedLibrary("z"),
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .target(name: "RDPKit", dependencies: ["CFreeRDP"]),
        // AppKit and Metal views over RDPKit. Imports no FreeRDP.
        .target(name: "RDPKitUI", dependencies: ["RDPKit"]),
        .testTarget(
            name: "RDPKitTests",
            dependencies: ["RDPKit"]
        ),
        .testTarget(
            name: "RDPKitUITests",
            dependencies: ["RDPKitUI"]
        )
    ]
)
