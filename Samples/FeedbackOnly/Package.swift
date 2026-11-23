// swift-tools-version:6.0
import PackageDescription

// Links only IndieCrumbFeedback, to show the Usage and Crash code is absent from the binary.
let package = Package(
    name: "FeedbackOnly",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "FeedbackOnly", dependencies: [.product(name: "IndieCrumbFeedback", package: "indiecrumb-swift")]),
    ]
)
