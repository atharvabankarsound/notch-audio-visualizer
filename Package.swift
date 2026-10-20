// swift-tools-version:5.9
// NotchWave — a live audio waveform that lives around the MacBook notch.
// Open this file in Xcode (File ▸ Open…) or build from Terminal with `swift build`.

import PackageDescription

let package = Package(
    name: "NotchWave",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "NotchWave",
            path: "Sources/NotchWave",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreMedia")
            ]
        )
    ]
)
