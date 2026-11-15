// swift-tools-version: 6.2
import PackageDescription

// Pure, platform-independent logic shared by the app and the monitor extension.
// No FamilyControls, DeviceActivity or CloudKit here, so `swift test` runs on the Mac.
let package = Package(
    name: "ThymeKit",
    platforms: [.iOS("26.4"), .macOS(.v26)],
    products: [
        .library(name: "ThymeCore", targets: ["ThymeCore"]),
        .executable(name: "thyme-inspect", targets: ["thyme-inspect"]),
    ],
    targets: [
        .target(name: "ThymeCore"),
        // Runs the reconstruction on a journal copied off a phone (see CLAUDE.md).
        .executableTarget(name: "thyme-inspect", dependencies: ["ThymeCore"]),
        .testTarget(name: "ThymeCoreTests", dependencies: ["ThymeCore"]),
    ]
)
