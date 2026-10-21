// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PokerEngine",
    products: [
        .library(name: "PokerEngine", targets: ["PokerEngine"]),
    ],
    targets: [
        .target(name: "PokerEngine"),
        .testTarget(name: "PokerEngineTests", dependencies: ["PokerEngine"]),
        .executableTarget(
            name: "AIConsole",
            dependencies: ["PokerEngine"],
            path: "Sources/AIConsole"
        ),
    ]
)
