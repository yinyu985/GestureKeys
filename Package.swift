// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GestureKeys",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GestureKeys", targets: ["GestureKeys"])],
    targets: [
        .target(name: "GestureCore", resources: [.process("Localization")]),
        .executableTarget(name: "GestureKeys", dependencies: ["GestureCore"]),
        .executableTarget(name: "GestureCoreChecks", dependencies: ["GestureCore"], path: "Tests/GestureCoreTests")
    ]
)
