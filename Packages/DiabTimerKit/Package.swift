// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiabTimerKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "TimerCore", targets: ["TimerCore"]),
        .library(name: "NightscoutKit", targets: ["NightscoutKit"]),
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    targets: [
        .target(name: "TimerCore"),
        .target(name: "NightscoutKit", dependencies: ["TimerCore"]),
        .target(name: "Persistence", dependencies: ["TimerCore", "NightscoutKit"]),
        .testTarget(name: "TimerCoreTests", dependencies: ["TimerCore"]),
        .testTarget(
            name: "NightscoutKitTests",
            dependencies: ["NightscoutKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
    ]
)
