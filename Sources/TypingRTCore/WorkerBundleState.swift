import Foundation

/// Distinguishes a build without a bundled worker from an app bundle that was
/// moved or renamed while running. In the latter case macOS keeps the old
/// bundle path, so the worker can no longer be resolved until a restart.
public enum WorkerBundleState: Sendable, Equatable {
    case bundled
    case notBundled
    case appMoved

    public static func evaluate(bundleURL: URL, serviceName: String,
                                fileManager: FileManager = .default) -> WorkerBundleState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .appMoved
        }
        let worker = bundleURL
            .appendingPathComponent("Contents/XPCServices/\(serviceName).xpc/Contents/MacOS/TranscriptionWorker")
        return fileManager.isExecutableFile(atPath: worker.path) ? .bundled : .notBundled
    }
}
