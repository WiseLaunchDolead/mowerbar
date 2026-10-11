// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MowerBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MowerBar", targets: ["MowerBar"])],
    targets: [
        .target(name: "MowerBarCore"),
        .executableTarget(name: "MowerBar", dependencies: ["MowerBarCore"]),
        .testTarget(name: "MowerBarCoreTests", dependencies: ["MowerBarCore"])
    ],
    swiftLanguageModes: [.v5]
)
