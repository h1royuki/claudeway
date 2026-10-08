// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Claudeway",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Claudeway", targets: ["Claudeway"])],
    targets: [
        .target(name: "SwitcherCore", resources: [.process("Resources")]),
        .executableTarget(name: "Claudeway", dependencies: ["SwitcherCore"]),
        .executableTarget(name: "SwitcherTests", dependencies: ["SwitcherCore"], path: "Tests/SwitcherCoreTests")
    ]
)
