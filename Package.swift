// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "typingRT",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "typingRT", targets: ["TypingRTApp"]),
        .library(name: "TypingRTCore", targets: ["TypingRTCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "TypingRTCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "TypingRTApp", dependencies: ["TypingRTCore"]),
        .testTarget(name: "TypingRTCoreTests", dependencies: ["TypingRTCore"]),
        .testTarget(name: "TypingRTAppTests", dependencies: ["TypingRTApp", "TypingRTCore"])
    ]
)
