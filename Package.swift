// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LodeRunnerPort",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LodeRunnerCore", targets: ["LodeRunnerCore"]),
        .executable(name: "LevelInspector", targets: ["LevelInspector"]),
        .executable(name: "LodeRunnerMac", targets: ["LodeRunnerMac"]),
    ],
    targets: [
        .target(name: "LodeRunnerCore", resources: [.process("Resources")]),
        .executableTarget(name: "LevelInspector", dependencies: ["LodeRunnerCore"]),
        .executableTarget(name: "LodeRunnerMac", dependencies: ["LodeRunnerCore"], exclude: ["Info.plist"]),
        .testTarget(name: "LodeRunnerCoreTests", dependencies: ["LodeRunnerCore"]),
    ]
)
