// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GlassTunnel",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GlassTunnel", targets: ["GlassTunnelApp"]),
        .library(name: "GTProtocol", targets: ["GTProtocol"]),
        .library(name: "GTTransport", targets: ["GTTransport"]),
        .library(name: "GTCapture", targets: ["GTCapture"]),
        .library(name: "GTInput", targets: ["GTInput"]),
        .library(name: "GTSecurity", targets: ["GTSecurity"]),
        .library(name: "GTAdapters", targets: ["GTAdapters"]),
    ],
    dependencies: [
        // WebRTC is consumed as a prebuilt XCFramework via stasel/WebRTC.
        // Pinned to a recent M-series release compatible with macOS 13+.
        .package(url: "https://github.com/stasel/WebRTC.git", from: "125.0.0"),
    ],
    targets: [
        .target(
            name: "GTProtocol",
            path: "Sources/Protocol"
        ),
        .target(
            name: "GTSecurity",
            dependencies: ["GTProtocol"],
            path: "Sources/Security"
        ),
        .target(
            name: "GTCapture",
            dependencies: ["GTProtocol"],
            path: "Sources/Capture"
        ),
        .target(
            name: "GTInput",
            dependencies: ["GTProtocol", "GTSecurity"],
            path: "Sources/Input"
        ),
        .target(
            name: "GTAdapters",
            dependencies: ["GTProtocol", "GTCapture", "GTInput", "GTSecurity"],
            path: "Sources/Adapters"
        ),
        // GTTransport owns Session / SessionManager which orchestrate every
        // other module, so it depends on Capture / Input / Adapters too.
        // None of those depend on GTTransport so no cycle.
        .target(
            name: "GTTransport",
            dependencies: [
                "GTProtocol",
                "GTSecurity",
                "GTCapture",
                "GTInput",
                "GTAdapters",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/Transport"
        ),
        .executableTarget(
            name: "GlassTunnelApp",
            dependencies: [
                "GTProtocol",
                "GTTransport",
                "GTCapture",
                "GTInput",
                "GTSecurity",
                "GTAdapters",
            ],
            path: "Sources/App",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "TerminalLiveHostHarness",
            dependencies: [
                "GTProtocol",
                "GTTransport",
                "GTCapture",
                "GTSecurity",
            ],
            path: "Sources/TerminalLiveHostHarness"
        ),
        .executableTarget(
            name: "CursorStateSnapshotTool",
            dependencies: ["GTAdapters"],
            path: "Sources/CursorStateSnapshotTool"
        ),
        .executableTarget(
            name: "CursorVisibleHistoryTool",
            dependencies: ["GTAdapters", "GTProtocol"],
            path: "Sources/CursorVisibleHistoryTool"
        ),
        .testTarget(
            name: "GTSecurityTests",
            dependencies: ["GTSecurity", "GTProtocol"],
            path: "Tests/GTSecurityTests"
        ),
        .testTarget(
            name: "GTProtocolTests",
            dependencies: ["GTProtocol"],
            path: "Tests/GTProtocolTests"
        ),
        .testTarget(
            name: "GTAdaptersTests",
            dependencies: ["GTAdapters", "GTInput", "GTProtocol"],
            path: "Tests/GTAdaptersTests"
        ),
        .testTarget(
            name: "GTCaptureTests",
            dependencies: ["GTCapture"],
            path: "Tests/GTCaptureTests"
        ),
        .testTarget(
            name: "GTTransportTests",
            dependencies: [
                "GTTransport",
                "GTProtocol",
                "GTCapture",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Tests/GTTransportTests"
        ),
        .testTarget(
            name: "GlassTunnelAppTests",
            dependencies: ["GlassTunnelApp"],
            path: "Tests/GlassTunnelAppTests"
        ),
    ]
)
