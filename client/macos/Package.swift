// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WiFiGlideMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WiFiGlideCore", targets: ["WiFiGlideCore"]),
        .executable(name: "wifi-glide", targets: ["wifi-glide"]),
    ],
    targets: [
        .target(
            name: "WiFiGlideCore",
            path: "Sources/WiFiGlideCore"
        ),
        .executableTarget(
            name: "wifi-glide",
            dependencies: ["WiFiGlideCore"],
            path: "Sources/wifi-glide"
        ),
        .testTarget(
            name: "WiFiGlideCoreTests",
            dependencies: ["WiFiGlideCore"],
            path: "Tests/WiFiGlideCoreTests"
        ),
    ]
)
