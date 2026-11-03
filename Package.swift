// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "USHRSettingsPanel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "USHRProtocol", targets: ["USHRProtocol"]),
        .library(name: "USHRDevice", targets: ["USHRDevice"]),
    ],
    targets: [
        .target(name: "USHRProtocol"),
        .target(name: "CUSBShim"),
        .target(
            name: "USHRDevice",
            dependencies: ["USHRProtocol", "CUSBShim"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .testTarget(name: "USHRDeviceTests", dependencies: ["USHRDevice", "USHRProtocol"]),
        .testTarget(name: "USHRProtocolTests", dependencies: ["USHRProtocol"]),
    ]
)
