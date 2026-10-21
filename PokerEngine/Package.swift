// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PokerEngine",
    targets: [
        .target(name: "PokerEngine"),
        .testTarget(name: "PokerEngineTests", dependencies: ["PokerEngine"]),
    ]
)
