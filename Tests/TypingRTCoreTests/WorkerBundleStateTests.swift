import Foundation
import Testing
@testable import TypingRTCore

struct WorkerBundleStateTests {
    private let service = "dev.typingrt.mac.development.TranscriptionWorker"

    private func makeBundle(withWorker: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkerBundleStateTests-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("typingRT.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/XPCServices/\(service).xpc/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: withWorker ? macOS : app, withIntermediateDirectories: true)
        if withWorker {
            let worker = macOS.appendingPathComponent("TranscriptionWorker")
            #expect(FileManager.default.createFile(atPath: worker.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        }
        return app
    }

    @Test func bundledWorkerIsDetected() throws {
        let app = try makeBundle(withWorker: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(WorkerBundleState.evaluate(bundleURL: app, serviceName: service) == .bundled)
    }

    @Test func previewWithoutWorkerIsNotBundled() throws {
        let app = try makeBundle(withWorker: false)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(WorkerBundleState.evaluate(bundleURL: app, serviceName: service) == .notBundled)
    }

    /// Reproduces renaming the project folder while the app keeps running:
    /// the launch path disappears and must not be reported as a preview build.
    @Test func renamedParentFolderIsReportedAsMoved() throws {
        let app = try makeBundle(withWorker: true)
        let root = app.deletingLastPathComponent()
        let renamed = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-renamed")
        try FileManager.default.moveItem(at: root, to: renamed)
        defer { try? FileManager.default.removeItem(at: renamed) }
        #expect(WorkerBundleState.evaluate(bundleURL: app, serviceName: service) == .appMoved)
        #expect(WorkerBundleState.evaluate(bundleURL: renamed.appendingPathComponent("typingRT.app"), serviceName: service) == .bundled)
    }
}
