// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TaskListBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "TaskListBar",
            path: "Sources/TaskListBar",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Collaboration")
            ]
        )
    ]
)
