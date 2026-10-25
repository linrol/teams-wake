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
        .package(path: "../swapr-trans"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "TeamsWake",
            dependencies: [
                .product(name: "SwaprTransKit", package: "swapr-trans"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/TeamsWake",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Translation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
