// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Orbit", targets: ["Orbit"])],
    targets: [
        .executableTarget(name: "Orbit"),
        .testTarget(name: "OrbitTests", dependencies: ["Orbit"])
    ]
)
