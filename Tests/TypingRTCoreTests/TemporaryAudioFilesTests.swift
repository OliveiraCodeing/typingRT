import Darwin
import Foundation
import Testing

@testable import TypingRTCore

struct TemporaryAudioFilesTests {
    @Test func cleanupIsNonrecursiveAndIsolatedToCurrentNamespace() throws {
        try isolated { base in
            let own = try TemporaryAudioFiles.prepareDirectory(namespace: "dev.typingrt.test", temporaryDirectory: base)
            let other = try TemporaryAudioFiles.prepareDirectory(
                namespace: "dev.typingrt.other", temporaryDirectory: base)
            let orphan = own.appendingPathComponent(recordingName())
            let foreign = own.appendingPathComponent("notes.wav")
            let sibling = other.appendingPathComponent(recordingName())
            let nested = own.appendingPathComponent(recordingName(), isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let nestedFile = nested.appendingPathComponent(recordingName())
            for url in [orphan, foreign, sibling, nestedFile] { try Data([1]).write(to: url) }
            _ = try TemporaryAudioFiles.prepareDirectory(namespace: "dev.typingrt.test", temporaryDirectory: base)
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            for url in [foreign, sibling, nestedFile] { #expect(FileManager.default.fileExists(atPath: url.path)) }
        }
    }

    @Test func cleanupRetainsSymlinksHardlinksAndTheirTargets() throws {
        try isolated { base in
            let own = try TemporaryAudioFiles.prepareDirectory(namespace: "dev.typingrt.test", temporaryDirectory: base)
            let target = base.appendingPathComponent("unrelated.wav")
            try Data([1, 2, 3]).write(to: target)
            let symbolic = own.appendingPathComponent(recordingName())
            let hard = own.appendingPathComponent(recordingName())
            try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
            try FileManager.default.linkItem(at: target, to: hard)
            _ = try TemporaryAudioFiles.prepareDirectory(namespace: "dev.typingrt.test", temporaryDirectory: base)
            #expect(try Data(contentsOf: target) == Data([1, 2, 3]))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symbolic.path) == target.path)
            #expect(FileManager.default.fileExists(atPath: hard.path))
        }
    }

    @Test func rejectsRootAndNamespaceSymlinksWithoutDeletingTargets() throws {
        for linkRoot in [true, false] {
            try isolated { base in
                let target = base.appendingPathComponent("foreign", isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                let file = target.appendingPathComponent(recordingName())
                try Data([7]).write(to: file)
                let root = base.appendingPathComponent("typingRT-audio", isDirectory: true)
                let link: URL
                if linkRoot {
                    link = root
                } else {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                    link = root.appendingPathComponent("dev.typingrt.test", isDirectory: true)
                }
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                #expect(throws: (any Error).self) {
                    try TemporaryAudioFiles.prepareDirectory(namespace: "dev.typingrt.test", temporaryDirectory: base)
                }
                #expect(try Data(contentsOf: file) == Data([7]))
            }
        }
    }

    @Test func directoryIsPrivateAndCleanupCanBeExplicitlySkipped() throws {
        try isolated { base in
            let own = try TemporaryAudioFiles.prepareDirectory(namespace: "dev.typingrt.test", temporaryDirectory: base)
            let file = own.appendingPathComponent(recordingName())
            try Data([1]).write(to: file)
            _ = try TemporaryAudioFiles.prepareDirectory(
                namespace: "dev.typingrt.test", temporaryDirectory: base, removeOrphans: false)
            #expect(FileManager.default.fileExists(atPath: file.path))
            for url in [own, own.deletingLastPathComponent()] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            }
        }
    }

    @Test func invalidNamespaceAndLookalikeFileNamesAreNeverAccepted() throws {
        try isolated { base in
            for namespace in ["", ".", "..", "../foreign", "/foreign", "name/child", "name\\child"] {
                #expect(throws: (any Error).self) {
                    try TemporaryAudioFiles.prepareDirectory(namespace: namespace, temporaryDirectory: base)
                }
            }
            let own = try TemporaryAudioFiles.prepareDirectory(namespace: "dev.typingrt.test", temporaryDirectory: base)
            let names = ["\(UUID()).wav", "\(UUID())-invalid.wav", recordingName() + ".bak", "notes.txt",
                         String(repeating: "😀", count: 18) + "x.wav"]
            for name in names { try Data([1]).write(to: own.appendingPathComponent(name)) }
            _ = try TemporaryAudioFiles.prepareDirectory(namespace: "dev.typingrt.test", temporaryDirectory: base)
            for name in names { #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent(name).path)) }
        }
    }

    private func recordingName() -> String { "\(UUID().uuidString)-\(UUID().uuidString).wav" }

    private func isolated(_ body: (URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "typingRT-cleanup-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }
}
