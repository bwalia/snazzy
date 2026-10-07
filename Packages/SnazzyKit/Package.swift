// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnazzyKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SnazzyCore", targets: ["SnazzyCore"]),
        .library(name: "Assistant", targets: ["Assistant"]),
        .library(name: "CaptureEngine", targets: ["CaptureEngine"]),
        .library(name: "Slides", targets: ["Slides"]),
        .library(name: "Builder", targets: ["Builder"]),
        .library(name: "MCP", targets: ["MCP"]),
        .library(name: "Live", targets: ["Live"]),
    ],
    targets: [
        .target(name: "SnazzyCore"),
        .target(name: "Assistant", dependencies: ["SnazzyCore"]),
        .target(name: "CaptureEngine", dependencies: ["SnazzyCore"]),
        .target(name: "Slides", dependencies: ["SnazzyCore"]),
        .target(name: "Builder", dependencies: ["SnazzyCore"]),
        .target(name: "MCP", dependencies: ["SnazzyCore"]),
        .target(name: "Live", dependencies: ["SnazzyCore"]),
        .testTarget(name: "SnazzyCoreTests", dependencies: ["SnazzyCore"]),
        .testTarget(name: "AssistantTests", dependencies: ["Assistant", "SnazzyCore"]),
        .testTarget(name: "BuilderTests", dependencies: ["Builder", "SnazzyCore"]),
        .testTarget(name: "MCPTests", dependencies: ["MCP", "SnazzyCore"]),
        .testTarget(name: "LiveTests", dependencies: ["Live", "SnazzyCore"]),
        .testTarget(name: "CaptureEngineTests", dependencies: ["CaptureEngine", "SnazzyCore"]),
    ]
)
