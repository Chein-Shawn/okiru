// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OkiruCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "OkiruCore", targets: ["OkiruCore"])],
    targets: [
        .target(name: "OkiruCore", path: "Sources/OkiruCore"),
        .testTarget(name: "OkiruCoreTests", dependencies: ["OkiruCore"], path: "Tests/OkiruCoreTests")
    ]
)
