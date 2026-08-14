// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RC001MacBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RC001Core", targets: ["RC001Core"]),
        .executable(name: "rc001-probe", targets: ["RC001Probe"]),
    ],
    targets: [
        .target(name: "RC001SharedAudio"),
        .target(name: "RC001Core", dependencies: ["RC001SharedAudio"]),
        .executableTarget(
            name: "RC001Probe",
            dependencies: ["RC001Core"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "RC001CoreTests",
            dependencies: ["RC001Core", "RC001SharedAudio"]
        ),
    ]
)
