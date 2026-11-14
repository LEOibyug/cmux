// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxControlCenter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxControlCenter", targets: ["CmuxControlCenter"])
    ],
    targets: [
        .target(
            name: "CmuxControlCenter",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault")
            ]
        ),
        .testTarget(
            name: "CmuxControlCenterTests",
            dependencies: ["CmuxControlCenter"]
        )
    ]
)
