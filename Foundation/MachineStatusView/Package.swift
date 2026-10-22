// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MachineStatusView",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "MachineStatusView",
            targets: ["MachineStatusView"]
        ),
    ],
    dependencies: [
        .package(name: "MachineStatus", path: "../MachineStatus"),
        .package(name: "TamioModule", path: "../TamioModule"),
    ],
    targets: [
        .target(
            name: "MachineStatusView",
            dependencies: ["MachineStatus", "TamioModule"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
