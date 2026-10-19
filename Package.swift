// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TingBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TingBridge",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreAudio"),
            ]
        )
    ]
)
