// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TypingRTTranscriptionWorker",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TranscriptionWorker", targets: ["TranscriptionWorker"])
    ],
    dependencies: [
        .package(name: "typingRT", path: "../.."),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")
    ],
    targets: [
        .executableTarget(
            name: "TranscriptionWorker",
            dependencies: [
                .product(name: "TypingRTCore", package: "typingRT"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            swiftSettings: [
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(name: "TranscriptionWorkerTests", dependencies: ["TranscriptionWorker"])
    ],
    swiftLanguageModes: [.v6]
)
