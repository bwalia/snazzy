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
        .library(name: "Broadcast", targets: ["Broadcast"]),
    ],
    // Third-party (approved): HaishinKit (BSD-3-Clause) for RTMP(S) streaming to
    // YouTube, Twitch and Vimeo. It brings Logboard (BSD-3-Clause). Pinned exactly.
    dependencies: [
        .package(url: "https://github.com/HaishinKit/HaishinKit.swift", exact: "2.2.5"),
    ],
    targets: [
        .target(name: "SnazzyCore"),
        .target(name: "Assistant", dependencies: ["SnazzyCore"]),
        .target(name: "CaptureEngine", dependencies: ["SnazzyCore"]),
        .target(name: "Slides", dependencies: ["SnazzyCore"]),
        .target(name: "Builder", dependencies: ["SnazzyCore"]),
        .target(name: "MCP", dependencies: ["SnazzyCore"]),
        .target(name: "Live", dependencies: ["SnazzyCore"]),
        .target(name: "Broadcast", dependencies: [
            "SnazzyCore", "CaptureEngine",
            .product(name: "RTMPHaishinKit", package: "HaishinKit.swift"),
            .product(name: "HaishinKit", package: "HaishinKit.swift"),
        ]),
        .testTarget(name: "SnazzyCoreTests", dependencies: ["SnazzyCore"]),
        .testTarget(name: "AssistantTests", dependencies: ["Assistant", "SnazzyCore"]),
        .testTarget(name: "BuilderTests", dependencies: ["Builder", "SnazzyCore"]),
        .testTarget(name: "MCPTests", dependencies: ["MCP", "SnazzyCore"]),
        .testTarget(name: "LiveTests", dependencies: ["Live", "SnazzyCore"]),
        .testTarget(name: "BroadcastTests", dependencies: ["Broadcast", "SnazzyCore"]),
        .testTarget(name: "CaptureEngineTests", dependencies: ["CaptureEngine", "SnazzyCore"]),
    ]
)
