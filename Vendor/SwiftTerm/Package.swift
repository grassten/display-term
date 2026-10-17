// swift-tools-version:6.0

// Vendored SwiftTerm 1.20.0 (commit 5d14406), trimmed to the library target and patched.
// See Vendor/SwiftTerm/PATCHES.md.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            resources: [
                .process("Apple/Metal/Shaders.metal")
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
