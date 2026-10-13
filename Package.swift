// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "SamsungMenubar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SamsungMenubar", targets: ["SamsungMenubar"])],
    targets: [
        .executableTarget(
            name: "SamsungMenubar",
            resources: [.copy("AppAssets")]
        )
    ]
)
