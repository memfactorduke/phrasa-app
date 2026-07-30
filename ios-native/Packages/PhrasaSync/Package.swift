// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhrasaSync",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        /// Pure local-first sync engine. No network SDK, no secrets.
        /// Safe to link into shipping apps that remain offline-only until
        /// platform code opts into `PhrasaSyncSupabase`.
        .library(name: "PhrasaSync", targets: ["PhrasaSync"]),
        /// Supabase transport adapter. Shipping-capable: only publishable keys
        /// via configuration; never embeds secrets. Link only when cloud is enabled.
        .library(name: "PhrasaSyncSupabase", targets: ["PhrasaSyncSupabase"]),
    ],
    dependencies: [
        .package(path: "../PhrasaDomain"),
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.51.0"),
    ],
    targets: [
        .target(
            name: "PhrasaSync",
            dependencies: ["PhrasaDomain"]
        ),
        .target(
            name: "PhrasaSyncSupabase",
            dependencies: [
                "PhrasaSync",
                "PhrasaDomain",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(
            name: "PhrasaSyncTests",
            dependencies: ["PhrasaSync", "PhrasaDomain"]
        ),
        .testTarget(
            name: "PhrasaSyncSupabaseTests",
            dependencies: ["PhrasaSyncSupabase", "PhrasaSync", "PhrasaDomain"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
