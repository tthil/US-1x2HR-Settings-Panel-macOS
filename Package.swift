// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "USHRSettingsPanel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "USHRProtocol", targets: ["USHRProtocol"]),
        .library(name: "USHRDevice", targets: ["USHRDevice"]),
        .library(name: "USHRPanelCore", targets: ["USHRPanelCore"]),
        .executable(name: "ushr-probe", targets: ["ushr-probe"]),
    ],
    targets: [
        .target(name: "USHRProtocol"),
        .target(name: "CUSBShim"),
        .target(
            name: "USHRDevice",
            dependencies: ["USHRProtocol", "CUSBShim"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "USHRPanelCore", dependencies: ["USHRProtocol"]),
        .executableTarget(name: "ushr-probe", dependencies: ["USHRProtocol", "USHRDevice"]),
        .testTarget(name: "USHRDeviceTests", dependencies: ["USHRDevice", "USHRProtocol"]),
        .testTarget(name: "USHRPanelCoreTests", dependencies: ["USHRPanelCore", "USHRProtocol"]),
        .testTarget(name: "USHRProtocolTests", dependencies: ["USHRProtocol"]),
    ]
)
