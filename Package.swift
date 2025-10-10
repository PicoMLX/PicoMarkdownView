// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PicoMarkdownView",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PicoMarkdownView",
            targets: ["PicoMarkdownView"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown", from: "0.4.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PicoMarkdownView",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .testTarget(
            name: "PicoMarkdownViewTests",
            dependencies: ["PicoMarkdownView"]
        ),
        .testTarget(
            name: "PicoMarkdownViewBenchmarks",
            dependencies: ["PicoMarkdownView"],
            resources: [
                .process("Benchmarks/sample1.md")
            ]
        ),
    ]
)
