import CryptoKit
import Foundation
import Testing
@testable import TypingRTCore

struct ModelInstallerTests {
    @Test
    func completePinnedInventoryActivatesAndRefreshesWithoutNetwork() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SyntheticModelTransport()
        let installer = ModelInstaller(rootURL: root, transport: transport)
        #expect(try await installer.installedModel(for: descriptor) == nil)
        #expect(await transport.requestCount == 0)

        let installed = try await installer.install(descriptor, progress: { _ in })
        #expect(installed.manifest.descriptor == descriptor)
        #expect(installed.manifest.assets.count == 15)
        #expect(installed.modelPath.lastPathComponent == "model")
        #expect(installed.tokenizerPath.lastPathComponent == "tokenizer")
        #expect(FileManager.default.fileExists(atPath: installed.modelPath.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin").path))
        let requestsAfterInstall = await transport.requestCount

        let refreshed = try await installer.installedModel(for: descriptor)
        #expect(refreshed?.manifest.installationID == installed.manifest.installationID)
        #expect(await transport.requestCount == requestsAfterInstall)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".staging-") })
        #expect(await transport.downloadedTokenizerFiles == Set(["tokenizer.json", "tokenizer_config.json"]))
    }

    @Test
    func sameSizeCorruptionIsNotAnInstalledModel() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(rootURL: root, transport: SyntheticModelTransport())
        let installed = try await installer.install(descriptor, progress: { _ in })
        let file = installed.modelPath.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")
        let original = try Data(contentsOf: file)
        try Data(repeating: 0x7f, count: original.count).write(to: file)

        await #expect(throws: ModelInstallationError.self) {
            try await installer.installedModel(for: descriptor)
        }
    }

    @Test
    func downloadIntegrityFailureLeavesNoActivatedOrStagingFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(rootURL: root, transport: SyntheticModelTransport(behavior: .corruptDownload))

        await #expect(throws: ModelInstallationError.self) {
            try await installer.install(descriptor, progress: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(try await installer.installedModel(for: descriptor) == nil)
    }

    @Test
    func cancelledDownloadRemovesStagingAndCanBeRetried() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SyntheticModelTransport(behavior: .cancelDownload)
        let installer = ModelInstaller(rootURL: root, transport: transport)

        await #expect(throws: CancellationError.self) {
            try await installer.install(descriptor, progress: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await transport.setBehavior(.normal)
        #expect(try await installer.install(descriptor, progress: { _ in }).manifest.descriptor == descriptor)
    }

    @Test
    func inventoryWithoutWeightsIsRejectedBeforeDownload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SyntheticModelTransport(behavior: .missingWeight)
        let installer = ModelInstaller(rootURL: root, transport: transport)

        await #expect(throws: ModelInstallationError.self) {
            try await installer.install(descriptor, progress: { _ in })
        }
        #expect(await transport.downloadCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func traversalFromRemoteInventoryIsRejectedBeforeDownload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SyntheticModelTransport(behavior: .unsafePath)
        let installer = ModelInstaller(rootURL: root, transport: transport)

        await #expect(throws: ModelInstallationError.self) {
            try await installer.install(descriptor, progress: { _ in })
        }
        #expect(await transport.downloadCount == 0)
    }

    @Test
    func validationRejectsSymlinkedInstalledAssets() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(rootURL: root, transport: SyntheticModelTransport())
        let installed = try await installer.install(descriptor, progress: { _ in })
        let file = installed.tokenizerPath.appendingPathComponent("tokenizer.json")
        let external = root.appendingPathComponent("separate-file")
        try Data(contentsOf: file).write(to: external)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)

        await #expect(throws: ModelInstallationError.self) {
            try await installer.installedModel(for: descriptor)
        }
    }

    private var descriptor: ModelDescriptor { ModelCatalog.compressedTurbo }
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-model-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor SyntheticModelTransport: ModelTransport {
    enum Behavior: Sendable { case normal, corruptDownload, cancelDownload, missingWeight, unsafePath }
    private var behavior: Behavior
    private(set) var requestCount = 0
    private(set) var downloadCount = 0
    private(set) var downloadedTokenizerFiles: Set<String> = []

    init(behavior: Behavior = .normal) { self.behavior = behavior }
    func setBehavior(_ value: Behavior) { behavior = value }

    func metadata(from url: URL) async throws -> ModelMetadataPage {
        requestCount += 1
        let descriptor = ModelCatalog.compressedTurbo
        let isTokenizer = url.path.contains("/openai/whisper-large-v3/")
        var paths: [String]
        if isTokenizer {
            paths = ["tokenizer.json", "tokenizer_config.json", "model.safetensors"]
        } else {
            paths = ["config.json", "generation_config.json"]
            for component in ModelIntegrity.components {
                paths += ["\(component)/coremldata.bin", "\(component)/metadata.json", "\(component)/model.mil"]
            }
            paths += ["AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/weights/weight.bin"]
            if behavior == .missingWeight { paths.removeAll { $0.contains("/weights/") } }
            if behavior == .unsafePath { paths.append("../../escape") }
            paths = paths.map { descriptor.subdirectory + "/" + $0 }
        }
        var entries: [[String: Any]] = []
        for path in paths {
            let content = payload(path: path)
            var entry: [String: Any] = ["type": "file", "path": path, "size": content.count]
            if path.hasSuffix(".bin") {
                entry["oid"] = String(repeating: "a", count: 40)
                entry["lfs"] = ["oid": ModelIntegrity.hex(SHA256.hash(data: content)), "size": content.count]
            } else {
                var git = Insecure.SHA1()
                git.update(data: Data("blob \(content.count)\0".utf8))
                git.update(data: content)
                entry["oid"] = ModelIntegrity.hex(git.finalize())
            }
            entries.append(entry)
        }
        return ModelMetadataPage(data: try JSONSerialization.data(withJSONObject: entries), nextURL: nil)
    }

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        requestCount += 1
        downloadCount += 1
        let descriptor = ModelCatalog.compressedTurbo
        let path: String
        if url.path.contains("/openai/whisper-large-v3/") {
            path = url.lastPathComponent
            downloadedTokenizerFiles.insert(path)
        } else {
            path = url.path.components(separatedBy: descriptor.revision + "/").last ?? ""
        }
        let content = payload(path: path)
        if behavior == .cancelDownload {
            try content.prefix(1).write(to: destination)
            throw CancellationError()
        }
        let actual = behavior == .corruptDownload ? Data(repeating: 0, count: content.count) : content
        try actual.write(to: destination)
        progress(Int64(actual.count))
    }

    private func payload(path: String) -> Data { Data("synthetic asset: \(path)".utf8) }
}
