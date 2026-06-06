// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sprout",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SproutEngine", targets: ["SproutEngine"]),
        .executable(name: "sprout", targets: ["sprout-cli"]),
        .executable(name: "SproutApp", targets: ["SproutApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
    ],
    targets: [
        .target(
            name: "SproutEngine",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]
        ),
        .executableTarget(
            name: "sprout-cli",
            dependencies: [
                "SproutEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "CSproutXPC"),
        .executableTarget(
            name: "SproutApp",
            dependencies: [
                "SproutEngine",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "SproutEngineTests",
            dependencies: ["SproutEngine"],
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
        .testTarget(
            name: "SproutAppTests",
            dependencies: ["SproutApp"]
        ),
    ]
)
