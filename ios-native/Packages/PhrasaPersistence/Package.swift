// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhrasaPersistence",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PhrasaPersistence", targets: ["PhrasaPersistence"]),
    ],
    dependencies: [
        .package(path: "../PhrasaDomain"),
    ],
    targets: [
        .target(
            name: "PhrasaPersistence",
            dependencies: ["PhrasaDomain"]
        ),
        .testTarget(
            name: "PhrasaPersistenceTests",
            dependencies: ["PhrasaPersistence", "PhrasaDomain"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
