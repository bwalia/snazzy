// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnazzyKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SnazzyCore", targets: ["SnazzyCore"]),
        .library(name: "Assistant", targets: ["Assistant"]),
        .library(name: "CaptureEngine", targets: ["CaptureEngine"]),
        .library(name: "Slides", targets: ["Slides"]),
        .library(name: "Builder", targets: ["Builder"]),
    ],
    targets: [
        .target(name: "SnazzyCore"),
        .target(name: "Assistant", dependencies: ["SnazzyCore"]),
        .target(name: "CaptureEngine", dependencies: ["SnazzyCore"]),
        .target(name: "Slides", dependencies: ["SnazzyCore"]),
        .target(name: "Builder", dependencies: ["SnazzyCore"]),
        .testTarget(name: "SnazzyCoreTests", dependencies: ["SnazzyCore"]),
        .testTarget(name: "AssistantTests", dependencies: ["Assistant", "SnazzyCore"]),
        .testTarget(name: "BuilderTests", dependencies: ["Builder"]),
        .testTarget(name: "CaptureEngineTests", dependencies: ["CaptureEngine", "SnazzyCore"]),
    ]
)
