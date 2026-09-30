// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChekiBenchmark",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ChekiBenchmark",
            path: "Sources",
            // Vision, CoreImage, CoreGraphics, ImageIO は macOS システムフレームワーク
            linkerSettings: [
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
