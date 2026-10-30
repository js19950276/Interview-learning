// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "genius-coder",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "PhoneProtocol", targets: ["PhoneProtocol"]),
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .executable(name: "genius-bridge-cli", targets: ["BridgeCLI"]),
    ],
    targets: [
        .target(
            name: "PhoneProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BridgeCore",
            dependencies: ["PhoneProtocol"],
            resources: [
                .copy("Resources/ClaudeHost.mjs"),
                .copy("Resources/ClaudeHost.package.json"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BridgeCLI",
            dependencies: ["BridgeCore", "PhoneProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PhoneProtocolTests",
            dependencies: ["PhoneProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore", "PhoneProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
