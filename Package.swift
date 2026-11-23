// swift-tools-version:6.0
import PackageDescription

// One product per module: an app links only what it uses, and the rest never enters its binary.
let package = Package(
    name: "IndieCrumb",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IndieCrumbCore", targets: ["IndieCrumbCore"]),
        .library(name: "IndieCrumbFeedback", targets: ["IndieCrumbFeedback"]),
        .library(name: "IndieCrumbUsage", targets: ["IndieCrumbUsage"]),
        .library(name: "IndieCrumbCrash", targets: ["IndieCrumbCrash"]),
    ],
    targets: [
        .target(name: "IndieCrumbCore"),
        .target(name: "IndieCrumbFeedback", dependencies: ["IndieCrumbCore"]),
        .target(name: "IndieCrumbUsage", dependencies: ["IndieCrumbCore"]),
        .target(name: "IndieCrumbCrash", dependencies: ["IndieCrumbCore"]),
        .testTarget(name: "IndieCrumbTests",
                    dependencies: ["IndieCrumbCore", "IndieCrumbFeedback", "IndieCrumbUsage", "IndieCrumbCrash"],
                    resources: [.copy("Fixtures")]),
    ]
)
