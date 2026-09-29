// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaliBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CaliBar", targets: ["CaliBar"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "CaliBarCore"),
        .executableTarget(name: "CaliBar", dependencies: ["CaliBarCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "CaliBarCoreTests", dependencies: ["CaliBarCore"])
    ]
)
