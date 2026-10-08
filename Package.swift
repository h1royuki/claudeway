// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Claudeway",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Claudeway", targets: ["Claudeway"])],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(name: "Claudeway", dependencies: ["SwitcherCore"]),
        .executableTarget(name: "SwitcherTests", dependencies: ["SwitcherCore"], path: "Tests/SwitcherCoreTests")
    ]
)
