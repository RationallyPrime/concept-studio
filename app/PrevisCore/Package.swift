// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrevisCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PrevisCore", targets: ["PrevisCore"])],
    targets: [
        .target(name: "PrevisCore", resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PrevisCoreTests", dependencies: ["PrevisCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
