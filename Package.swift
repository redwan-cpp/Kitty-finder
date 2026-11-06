// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KittyFinder",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: paths, accounts, rclone arguments, process running, stats parsing.
        .target(name: "KittyFinderCore", path: "Sources/KittyFinderCore"),
        // The menu bar app.
        .executableTarget(name: "KittyFinder", dependencies: ["KittyFinderCore"], path: "Sources/KittyFinder"),
        .testTarget(name: "KittyFinderCoreTests", dependencies: ["KittyFinderCore"], path: "Tests/KittyFinderCoreTests"),
    ]
)
