// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacDisplay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacDisplay", targets: ["MacDisplay"])
    ],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MacDisplay",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/MacDisplay"
        )
    ]
)
