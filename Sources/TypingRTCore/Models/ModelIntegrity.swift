import CryptoKit
import Foundation

enum ModelIntegrity {
    static let tokenizerFiles: Set<String> = ["tokenizer.json", "tokenizer_config.json"]
    static let components = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]

    static func validHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validateRelativePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ModelInstallationError.invalidPath
        }
    }

    static func fileURL(root: URL, path: String) throws -> URL {
        try validateRelativePath(path)
        var result = root
        for part in path.split(separator: "/") {
            result.appendPathComponent(String(part))
            if FileManager.default.fileExists(atPath: result.path),
               try result.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw ModelInstallationError.invalidPath
            }
        }
        return result
    }

    static func validateDescriptor(_ descriptor: ModelDescriptor) throws {
        try validateRelativePath(descriptor.id)
        try validateRelativePath(descriptor.repository)
        try validateRelativePath(descriptor.subdirectory)
        try validateRelativePath(descriptor.tokenizerRepository)
        guard !descriptor.id.contains("/"), descriptor.repository.split(separator: "/").count == 2,
              descriptor.tokenizerRepository.split(separator: "/").count == 2,
              validHex(descriptor.revision, length: 40), validHex(descriptor.tokenizerRevision, length: 40) else {
            throw ModelInstallationError.invalidDescriptor
        }
    }

    static func validateRequiredPaths(_ paths: [String]) throws {
        let set = Set(paths)
        guard set.count == paths.count, !paths.isEmpty,
              set.contains("model/config.json"), set.contains("model/generation_config.json"),
              tokenizerFiles.allSatisfy({ set.contains("tokenizer/\($0)") }) else {
            throw ModelInstallationError.missingRequiredAssets
        }
        for component in components {
            for filename in ["coremldata.bin", "metadata.json", "model.mil"] {
                guard set.contains("model/\(component)/\(filename)") else {
                    throw ModelInstallationError.missingRequiredAssets
                }
            }
        }
        for component in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            guard set.contains("model/\(component)/weights/weight.bin") else {
                throw ModelInstallationError.missingRequiredAssets
            }
        }
    }

    static func inventoryHash(_ assets: [InstalledModelAsset]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hex(SHA256.hash(data: try encoder.encode(assets.sorted { $0.path < $1.path })))
    }

    /// Bounded reads, outside MainActor. SHA-1 is only the Git blob identity of
    /// ordinary repository files; all installed files additionally get SHA-256.
    static func hashFile(
        _ url: URL, byteCount: Int64, expectedSHA256: String? = nil, expectedGitBlob: String? = nil
    ) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == byteCount, byteCount >= 0 else {
            throw ModelInstallationError.integrityFailure
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha256 = SHA256()
        var gitSHA1 = Insecure.SHA1()
        if expectedGitBlob != nil { gitSHA1.update(data: Data("blob \(byteCount)\0".utf8)) }
        var read: Int64 = 0
        while let chunk = try file.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            read += Int64(chunk.count)
            guard read <= byteCount else { throw ModelInstallationError.integrityFailure }
            sha256.update(data: chunk)
            if expectedGitBlob != nil { gitSHA1.update(data: chunk) }
        }
        let digest = hex(sha256.finalize())
        guard read == byteCount,
              expectedSHA256 == nil || expectedSHA256 == digest,
              expectedGitBlob == nil || expectedGitBlob == hex(gitSHA1.finalize()) else {
            throw ModelInstallationError.integrityFailure
        }
        return digest
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
