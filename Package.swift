// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "USHRSettingsPanel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "USHRProtocol", targets: ["USHRProtocol"]),
    ],
    targets: [
        .target(name: "USHRProtocol"),
        .testTarget(name: "USHRProtocolTests", dependencies: ["USHRProtocol"]),
    ]
)
