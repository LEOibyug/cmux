// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxTui",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxTui", targets: ["CmuxTui"])],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxSurfaceCatalogModel"),
        .package(path: "../CmuxTerminal"),
        .package(path: "../../Shared/CmuxTerminalSizing")
    ],
    targets: [
        .target(
            name: "CmuxTui",
            dependencies: ["CmuxFoundation", "CmuxSurfaceCatalogModel", "CmuxTerminal", "CmuxTerminalSizing"],
            // The files moved out of the app target unchanged; keep its language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CmuxTuiTests",
            dependencies: [
                "CmuxTui",
                // CmuxTerminal binds libghostty, which SwiftPM cannot link here.
                .product(name: "CmuxTerminalGhosttyRuntimeTestStubs", package: "CmuxTerminal"),
            ]
        )
    ]
)
