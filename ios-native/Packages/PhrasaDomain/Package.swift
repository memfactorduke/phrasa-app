// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhrasaDomain",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PhrasaDomain", targets: ["PhrasaDomain"]),
    ],
    targets: [
        .target(name: "PhrasaDomain"),
        .testTarget(
            name: "PhrasaDomainTests",
            dependencies: ["PhrasaDomain"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
