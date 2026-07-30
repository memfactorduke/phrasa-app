// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhrasaCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PhrasaCore", targets: ["PhrasaCore"]),
    ],
    targets: [
        .target(name: "PhrasaCore"),
        .testTarget(
            name: "PhrasaCoreTests",
            dependencies: ["PhrasaCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
