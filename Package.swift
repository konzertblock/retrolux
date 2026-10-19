// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Retrolux",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Retrolux", targets: ["Retrolux"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")],
    targets: [
        .target(name: "RetroluxCore", path: "Sources/RetroluxCore", swiftSettings: v5),
        .executableTarget(name: "Retrolux", dependencies: ["RetroluxCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/Retrolux", swiftSettings: v5),
        .testTarget(name: "RetroluxCoreTests", dependencies: ["RetroluxCore"], path: "Tests/RetroluxCoreTests", swiftSettings: v5),
    ]
)
