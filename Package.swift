// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TeamsWake",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(
            name: "TeamsWake",
            targets: ["TeamsWake"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/linrol/swapr-trans.git", from: "1.0.4"),
        .package(url: "https://github.com/linrol/katib.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TeamsWake",
            dependencies: [
                .product(name: "SwaprTransKit", package: "swapr-trans"),
                .product(name: "KatibKit", package: "katib")
            ],
            path: "Sources/TeamsWake",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Translation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
