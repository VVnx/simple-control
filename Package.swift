// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RC001MacBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RC001Core", targets: ["RC001Core"]),
        .executable(name: "rc001-probe", targets: ["RC001Probe"]),
        .executable(name: "rc001-hid-helper", targets: ["RC001HIDHelper"]),
    ],
    targets: [
        .target(name: "RC001SharedAudio"),
        .target(name: "RC001Core", dependencies: ["RC001SharedAudio"]),
        .target(name: "RC001HIDBridgeProtocol"),
        .executableTarget(
            name: "RC001Probe",
            dependencies: ["RC001Core", "RC001HIDBridgeProtocol"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
            ]
        ),
        .executableTarget(
            name: "RC001HIDHelper",
            dependencies: ["RC001HIDBridgeProtocol"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "RC001CoreTests",
            dependencies: ["RC001Core", "RC001SharedAudio", "RC001HIDBridgeProtocol"]
        ),
    ]
)
