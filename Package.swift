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
        // Renderer guidance without linking TextKit, SwiftMath or OpenUI.
        .library(
            name: "PicoMarkdownSkills",
            targets: ["PicoMarkdownSkills"]
        ),
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PicoMarkdownView",
            targets: ["PicoMarkdownView"]
        ),
        // Separate, opt-in macOS HTML preview adapter.
        .library(
            name: "PicoMarkdownViewHTML",
            targets: ["PicoMarkdownViewHTML"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/mgriebling/SwiftMath.git", .upToNextMajor(from: "1.7.3")),
        // Test-only: cmark-gfm through Apple's wrapper, the reference parser
        // the conformance suite compares against. Not linked by the library.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "release/6.2")
    ],
    targets: [
        .target(
            name: "PicoMarkdownSkills",
            path: "Skills",
            sources: ["PicoMarkdownSkills.swift"],
            resources: [
                .copy("pele-diagrams"),
                .copy("svg-graphics"),
                .copy("vega-lite-charts"),
                .copy("openui-interfaces"),
                .copy("html-previews")
            ]
        ),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PicoMarkdownView",
            dependencies: [
                .product(name: "SwiftMath", package: "SwiftMath"),
                .target(name: "PicoOpenUIRuntime", condition: .when(platforms: [.macOS]))
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "PicoMarkdownViewHTML",
            dependencies: ["PicoMarkdownView"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PicoMarkdownViewHTMLTests",
            dependencies: ["PicoMarkdownViewHTML", "PicoMarkdownSkills"]
        ),
        // Explicitly opt-in real-window latency/memory experiments; excluded from CI.
        .testTarget(
            name: "PicoMarkdownViewHTMLBenchmarks",
            dependencies: ["PicoMarkdownView", "PicoMarkdownViewHTML"]
        ),
        .target(
            name: "PicoOpenUIRuntime",
            resources: [.copy("Resources/OpenUI")]
        ),
        .testTarget(
            name: "PicoMarkdownViewTests",
            dependencies: ["PicoMarkdownView", "PicoMarkdownSkills"]
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
