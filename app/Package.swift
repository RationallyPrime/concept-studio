// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConceptStudio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ConceptCore", targets: ["ConceptCore"]),
        .executable(name: "ConceptStudio", targets: ["ConceptStudio"]),
        .executable(name: "shots-export", targets: ["ShotsExportTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.2"),
        // Mirror of Microsoft's 1.24.2 bindings and checksum-verified release archives.
        .package(url: "https://github.com/tryAGI/onnxruntime-swift-package-manager.git",
                 revision: "39ec45a96a53b3cacbef38a6fbf0fb27fa6d5369"),
        .package(path: "PrevisCore"),
    ],
    targets: [
        .target(
            name: "ConceptCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            resources: [.copy("Resources/Skills")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ShotsMedia",
            dependencies: [.product(name: "PrevisCore", package: "PrevisCore"), "ConceptCore"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ShotsExportTool",
            dependencies: ["ShotsMedia"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ConceptStudio",
            dependencies: [
                "ConceptCore", .product(name: "Yams", package: "Yams"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "PrevisCore", package: "PrevisCore"), "ShotsMedia",
            ],
            resources: [
                .copy("Resources/Demo"), .process("Resources/OpenAI"), .copy("Resources/Training"),
                .copy("Resources/Glossary"), .copy("Resources/Fonts"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("AVKit")]
        ),
        .testTarget(
            name: "ConceptCoreTests",
            dependencies: ["ConceptCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConceptStudioTests",
            dependencies: ["ConceptStudio"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ShotsMediaTests",
            dependencies: ["ShotsMedia", .product(name: "PrevisCore", package: "PrevisCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
