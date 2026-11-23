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
        // SwiftUI: "Report a problem" and the privacy switch. The crash parts live in IndieCrumbCrashUI,
        // so an app without IndieCrumbCrash never links MetricKit through the UI.
        .library(name: "IndieCrumbUI", targets: ["IndieCrumbUI"]),
        .library(name: "IndieCrumbCrashUI", targets: ["IndieCrumbCrashUI"]),
    ],
    targets: [
        .target(name: "IndieCrumbCore"),
        .target(name: "IndieCrumbFeedback", dependencies: ["IndieCrumbCore"]),
        .target(name: "IndieCrumbUsage", dependencies: ["IndieCrumbCore"]),
        .target(name: "IndieCrumbCrash", dependencies: ["IndieCrumbCore"]),
        .target(name: "IndieCrumbUI", dependencies: ["IndieCrumbCore", "IndieCrumbFeedback"]),
        .target(name: "IndieCrumbCrashUI", dependencies: ["IndieCrumbUI", "IndieCrumbCrash"]),
        .testTarget(name: "IndieCrumbTests",
                    dependencies: ["IndieCrumbCore", "IndieCrumbFeedback", "IndieCrumbUsage", "IndieCrumbCrash",
                                   "IndieCrumbUI", "IndieCrumbCrashUI"],
                    resources: [.copy("Fixtures")]),
    ]
)
