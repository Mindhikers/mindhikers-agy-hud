// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "MindHikersAgyHUD",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MindHikersAgyHUD", targets: ["MindHikersAgyHUD"])
    ],
    targets: [
        .executableTarget(
            name: "MindHikersAgyHUD",
            path: "Sources/MindHikersAgyHUD"
        )
    ]
)
