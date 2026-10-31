// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PicoMarkdownView",
    defaultLocalization: "en",
    platforms: [
        .macOS("27.0"),
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
        .package(url: "https://github.com/mgriebling/SwiftMath.git", .upToNextMajor(from: "1.7.3")),
        // Test-only: cmark-gfm through Apple's wrapper, the reference parser
        // the conformance suite compares against. Not linked by the library.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "release/6.2")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PicoMarkdownView",
            dependencies: [
                .product(name: "SwiftMath", package: "SwiftMath")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PicoMarkdownViewTests",
            dependencies: ["PicoMarkdownView"]
        ),
        // CommonMark conformance: every spec example parsed by PicoMarkdownView
        // and by cmark-gfm (swift-markdown), compared as block structure, with
        // a ratchet of known deviations. Its own target so the reference
        // parser and the vendored spec stay out of the unit-test target.
        .testTarget(
            name: "PicoMarkdownViewConformance",
            dependencies: [
                "PicoMarkdownView",
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Conformance",
            resources: [
                // Copied as a directory. Not named `Resources`: a bundle with a
                // top-level folder of that name fails codesign on the simulator.
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "PicoMarkdownViewBenchmarks",
            dependencies: ["PicoMarkdownView"],
            exclude: [
                "benchmark-results.md",
                "vega-gallery-results.md"
            ],
            resources: [
                .process("Benchmarks/sample1.md")
            ]
        ),
    ]
)
