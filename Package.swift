// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeelBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "KeelBar",
            path: "Sources/TaskListBar",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Collaboration"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("EventKit")
            ]
        ),
        .testTarget(
            name: "KeelBarTests",
            dependencies: ["KeelBar"],
            path: "Tests/KeelBarTests"
        )
    ]
)
