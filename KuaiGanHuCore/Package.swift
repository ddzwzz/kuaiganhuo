// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KuaiGanHuCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "KuaiGanHuCore", targets: ["KuaiGanHuCore"])
    ],
    targets: [
        .target(name: "KuaiGanHuCore"),
        .testTarget(name: "KuaiGanHuCoreTests", dependencies: ["KuaiGanHuCore"])
    ]
)
