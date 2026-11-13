import Foundation

public actor ModelInstaller: ModelInstallerProtocol {
    private let root: URL
    private let transport: any ModelTransport
    private var activeInstallation: UUID?

    public init(rootURL: URL = ModelCatalog.defaultRoot) {
        root = rootURL
        transport = URLSessionModelTransport()
    }

    init(rootURL: URL, transport: any ModelTransport) {
        root = rootURL
        self.transport = transport
    }

    public func installedModel(for descriptor: ModelDescriptor) async throws -> InstalledModel? {
        try validatedInstallation(for: descriptor)
    }

    public func install(
        _ descriptor: ModelDescriptor,
        progress: @escaping @Sendable (ModelInstallProgress) -> Void
    ) async throws -> InstalledModel {
        guard activeInstallation == nil else { throw ModelInstallationError.busy }
        try ModelIntegrity.validateDescriptor(descriptor)
        try Task.checkCancellation()
        let installationID = UUID()
        activeInstallation = installationID
        defer { activeInstallation = nil }
        if let existing = try? validatedInstallation(for: descriptor) { return existing }
        try Task.checkCancellation()

        progress(ModelInstallProgress(phase: .resolving, completedBytes: 0, totalBytes: 0))
        let assets = try await resolveAssets(for: descriptor)
        var totalSize: Int64 = 0
        for asset in assets {
            let addition = totalSize.addingReportingOverflow(asset.byteCount)
            guard !addition.overflow else { throw ModelInstallationError.invalidInventory }
            totalSize = addition.partialValue
        }
        let total = totalSize
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ModelInstallationError.invalidPath
        }
        let staging = root.appendingPathComponent(".staging-\(installationID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var cleanup: URL? = staging
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }

        var installed: [InstalledModelAsset] = []
        var completed: Int64 = 0
        for asset in assets {
            try Task.checkCancellation()
            let destination = try ModelIntegrity.fileURL(root: staging, path: asset.localPath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previous = completed
            try await transport.download(from: asset.url, to: destination) { bytes in
                progress(ModelInstallProgress(
                    phase: .downloading,
                    completedBytes: previous + min(asset.byteCount, max(0, bytes)), totalBytes: total
                ))
            }
            try Task.checkCancellation()
            progress(ModelInstallProgress(phase: .verifying, completedBytes: completed, totalBytes: total))
            let hash = try ModelIntegrity.hashFile(
                destination, byteCount: asset.byteCount,
                expectedSHA256: asset.sha256, expectedGitBlob: asset.gitBlob
            )
            installed.append(InstalledModelAsset(path: asset.localPath, byteCount: asset.byteCount, sha256: hash))
            completed += asset.byteCount
        }
        installed.sort { $0.path < $1.path }
        let manifest = InstalledModelManifest(
            schemaVersion: 1, installationID: installationID, descriptor: descriptor,
            installedAt: Date(), assets: installed, inventorySHA256: try ModelIntegrity.inventoryHash(installed)
        )
        try encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try Task.checkCancellation()
        progress(ModelInstallProgress(phase: .activating, completedBytes: total, totalBytes: total))

        // Immutable installation directories plus an atomic pointer preserve an old
        // installation until every new asset and its manifest have been verified.
        let finalName = "\(descriptor.id)-\(installationID.uuidString)"
        let final = root.appendingPathComponent(finalName, isDirectory: true)
        try FileManager.default.moveItem(at: staging, to: final)
        cleanup = final
        try encode(CurrentInstallation(directory: finalName)).write(to: pointer(for: descriptor), options: .atomic)
        cleanup = nil
        return InstalledModel(manifest: manifest, directory: final)
    }

    private func validatedInstallation(for descriptor: ModelDescriptor) throws -> InstalledModel? {
        try ModelIntegrity.validateDescriptor(descriptor)
        let pointerURL = pointer(for: descriptor)
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        do {
            let current = try JSONDecoder().decode(CurrentInstallation.self, from: limitedData(pointerURL))
            try ModelIntegrity.validateRelativePath(current.directory)
            guard !current.directory.contains("/"), current.directory.hasPrefix(descriptor.id + "-") else {
                throw ModelInstallationError.invalidInstallation
            }
            let directory = try ModelIntegrity.fileURL(root: root, path: current.directory)
            let manifestURL = try ModelIntegrity.fileURL(root: directory, path: "manifest.json")
            let manifest = try JSONDecoder().decode(InstalledModelManifest.self, from: limitedData(manifestURL))
            guard manifest.schemaVersion == 1, manifest.descriptor == descriptor,
                  (1...2_000).contains(manifest.assets.count),
                  try manifest.inventorySHA256 == ModelIntegrity.inventoryHash(manifest.assets) else {
                throw ModelInstallationError.invalidInstallation
            }
            try ModelIntegrity.validateRequiredPaths(manifest.assets.map(\.path))
            for asset in manifest.assets {
                try Task.checkCancellation()
                guard ModelIntegrity.validHex(asset.sha256, length: 64) else {
                    throw ModelInstallationError.invalidInstallation
                }
                let file = try ModelIntegrity.fileURL(root: directory, path: asset.path)
                _ = try ModelIntegrity.hashFile(file, byteCount: asset.byteCount, expectedSHA256: asset.sha256)
            }
            return InstalledModel(manifest: manifest, directory: directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ModelInstallationError.invalidInstallation
        }
    }

    private func resolveAssets(for descriptor: ModelDescriptor) async throws -> [RemoteModelAsset] {
        let model = try await inventory(
            repository: descriptor.repository, revision: descriptor.revision,
            subdirectory: descriptor.subdirectory
        )
        let tokenizer = try await inventory(
            repository: descriptor.tokenizerRepository, revision: descriptor.tokenizerRevision, subdirectory: nil
        )
        var assets: [RemoteModelAsset] = []
        for file in model {
            guard file.path.hasPrefix(descriptor.subdirectory + "/") else { throw ModelInstallationError.invalidPath }
            let relative = String(file.path.dropFirst(descriptor.subdirectory.count + 1))
            assets.append(try remoteAsset(file, localPath: "model/" + relative, repository: descriptor.repository, revision: descriptor.revision))
        }
        for file in tokenizer where ModelIntegrity.tokenizerFiles.contains(file.path) {
            assets.append(try remoteAsset(file, localPath: "tokenizer/" + file.path, repository: descriptor.tokenizerRepository, revision: descriptor.tokenizerRevision))
        }
        try ModelIntegrity.validateRequiredPaths(assets.map(\.localPath))
        return assets.sorted { $0.localPath < $1.localPath }
    }

    private func inventory(repository: String, revision: String, subdirectory: String?) async throws -> [HubTreeFile] {
        var url = URL(string: "https://huggingface.co/api/models")!
        for part in repository.split(separator: "/") { url.appendPathComponent(String(part)) }
        url.appendPathComponent("tree")
        url.appendPathComponent(revision)
        if let subdirectory {
            for part in subdirectory.split(separator: "/") { url.appendPathComponent(String(part)) }
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true"), URLQueryItem(name: "expand", value: "false"), URLQueryItem(name: "limit", value: "1000")]
        var next = components.url
        var pages = 0
        var files: [HubTreeFile] = []
        var visited: Set<URL> = []
        while let request = next {
            try Task.checkCancellation()
            pages += 1
            guard pages <= 10, visited.insert(request).inserted else { throw ModelInstallationError.invalidInventory }
            let page = try await transport.metadata(from: request)
            let entries = try JSONDecoder().decode([HubTreeFile].self, from: page.data)
            files.append(contentsOf: entries.filter { $0.type == "file" })
            guard files.count <= 2_000 else { throw ModelInstallationError.invalidInventory }
            if let nextURL = page.nextURL {
                guard nextURL.scheme == "https", nextURL.host == url.host, nextURL.path == url.path else {
                    throw ModelInstallationError.invalidInventory
                }
            }
            next = page.nextURL
        }
        return files
    }

    private func remoteAsset(_ file: HubTreeFile, localPath: String, repository: String, revision: String) throws -> RemoteModelAsset {
        try ModelIntegrity.validateRelativePath(localPath)
        try ModelIntegrity.validateRelativePath(file.path)
        guard let size = file.size, size >= 0 else { throw ModelInstallationError.invalidInventory }
        var sha256: String?
        var gitBlob: String?
        if let lfs = file.lfs {
            guard ModelIntegrity.validHex(lfs.oid, length: 64), lfs.size == size else {
                throw ModelInstallationError.unsupportedDigest
            }
            sha256 = lfs.oid
        } else {
            guard let oid = file.oid, ModelIntegrity.validHex(oid, length: 40) else {
                throw ModelInstallationError.unsupportedDigest
            }
            gitBlob = oid
        }
        var url = URL(string: "https://huggingface.co")!
        for part in repository.split(separator: "/") { url.appendPathComponent(String(part)) }
        url.appendPathComponent("resolve")
        url.appendPathComponent(revision)
        for part in file.path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return RemoteModelAsset(localPath: localPath, byteCount: size, sha256: sha256, gitBlob: gitBlob, url: url)
    }

    private func pointer(for descriptor: ModelDescriptor) -> URL {
        root.appendingPathComponent("\(descriptor.id).current.json")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func limitedData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 2 * 1_024 * 1_024 else {
            throw ModelInstallationError.invalidInstallation
        }
        return try Data(contentsOf: url)
    }
}

private struct CurrentInstallation: Codable {
    let directory: String
}

private struct RemoteModelAsset: Sendable {
    let localPath: String
    let byteCount: Int64
    let sha256: String?
    let gitBlob: String?
    let url: URL
}

private struct HubTreeFile: Decodable {
    let type: String
    let path: String
    let size: Int64?
    let oid: String?
    let lfs: LFS?

    struct LFS: Decodable {
        let oid: String
        let size: Int64
    }
}
