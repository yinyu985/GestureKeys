// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GestureKeys",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GestureKeys", targets: ["GestureKeys"])],
    targets: [
        .target(name: "GestureCore"),
        .executableTarget(name: "GestureKeys", dependencies: ["GestureCore"]),
        .executableTarget(name: "GestureCoreChecks", dependencies: ["GestureCore"], path: "Tests/GestureCoreTests")
    ]
)
