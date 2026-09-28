// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RealDeviceHub",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "RealDeviceHub",
            path: "Sources"
        )
    ]
)
