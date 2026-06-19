// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ComputerControl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ComputerControl", targets: ["ComputerControl"])
    ],
    targets: [
        .executableTarget(
            name: "ComputerControl",
            path: "Sources/ComputerControl",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "ComputerControlTests",
            dependencies: ["ComputerControl"],
            path: "Tests/ComputerControlTests"
        )
    ]
)
