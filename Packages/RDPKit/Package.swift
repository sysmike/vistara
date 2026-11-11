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
        .library(name: "RDPKit", targets: ["RDPKit"])
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
            linkerSettings: [
                .unsafeFlags(["-L\(freeRDPPrefix)/lib"]),
                .linkedLibrary("freerdp-client3"),
                .linkedLibrary("freerdp3"),
                .linkedLibrary("winpr3")
            ]
        ),
        .target(name: "RDPKit", dependencies: ["CFreeRDP"]),
        .testTarget(
            name: "RDPKitTests",
            dependencies: ["RDPKit"],
            // Tests run outside an app bundle, so they find the libraries in
            // the build prefix. The app embeds them instead (see project.yml).
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(freeRDPPrefix)/lib"])
            ]
        )
    ]
)
