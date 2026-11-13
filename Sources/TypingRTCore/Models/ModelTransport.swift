import Foundation

struct ModelMetadataPage: Sendable {
    let data: Data
    let nextURL: URL?
}

protocol ModelTransport: Sendable {
    func metadata(from url: URL) async throws -> ModelMetadataPage
    func download(
        from url: URL, to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

final class URLSessionModelTransport: ModelTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        session = URLSession(configuration: configuration)
    }

    func metadata(from url: URL) async throws -> ModelMetadataPage {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 16 * 1_024 * 1_024 else { throw ModelInstallationError.invalidResponse }
        var nextURL: URL?
        if let link = response.value(forHTTPHeaderField: "Link") {
            for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
                guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end,
                      let next = URL(string: String(part[part.index(after: start)..<end])),
                      next.scheme == "https", next.host == url.host, next.path == url.path else {
                    throw ModelInstallationError.invalidResponse
                }
                nextURL = next
            }
        }
        return ModelMetadataPage(data: data, nextURL: nextURL)
    }

    func download(
        from url: URL, to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let delegate = ModelDownloadProgress(progress: progress)
        let (temporary, response) = try await session.download(from: url, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https" else { throw ModelInstallationError.invalidResponse }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        progress(Int64(size))
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let callback: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var lastNotification = ContinuousClock.now

    init(progress: @escaping @Sendable (Int64) -> Void) { callback = progress }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let notify = lock.withLock {
            let now = ContinuousClock.now
            guard lastNotification.duration(to: now) >= .milliseconds(100) else { return false }
            lastNotification = now
            return true
        }
        if notify { callback(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
