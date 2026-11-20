// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OctiMonitor",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "OctiMonitor", targets: ["OctiMonitor"]),
    ],
    targets: [
        .target(
            name: "OctiMonitor",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "OctiMonitorTests",
            dependencies: ["OctiMonitor"]
        ),
    ]
)
