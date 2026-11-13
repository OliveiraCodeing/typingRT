import Foundation

/// The service never retries automatically: a failed POST may still have been billed.
/// Callers keep session ownership and deliberately repeat with the same session ID.
public final class RequestyClient: RequestyServing, @unchecked Sendable {
    private let session: URLSession
    private let redirects = RequestyRedirectDelegate()
    private static let base = "https://router.requesty.ai/v1"
    public static let maximumModelsBytes = 4 * 1_024 * 1_024
    public static let maximumCompletionBytes = 1_024 * 1_024

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func models(apiKey: String) async throws -> [RequestyModel] {
        let request = try makeRequest(path: "/models", apiKey: apiKey)
        let data = try await perform(request, maximumBytes: Self.maximumModelsBytes)
        do {
            let envelope = try JSONDecoder().decode(ModelEnvelope.self, from: data)
            guard envelope.data.count <= 10_000 else { throw RequestyError.tooLarge }
            var seen: Set<String> = []
            let result = envelope.data.compactMap { item -> RequestyModel? in
                guard item.api == "chat", let id = RequestyValidation.modelID(item.id),
                      item.outputModalities == nil || item.outputModalities!.contains("text"),
                      seen.insert(id).inserted else { return nil }
                return RequestyModel(id: id, contextWindow: item.contextWindow.flatMap { $0 > 0 ? $0 : nil },
                                     maxOutputTokens: item.maxOutputTokens.flatMap { $0 > 0 ? $0 : nil })
            }.sorted { $0.id < $1.id }
            try Task.checkCancellation()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as RequestyError { throw error }
        catch { throw RequestyError.invalidResponse }
    }

    public func complete(sessionID: UUID, modelID: String, system: String, text: String,
                         maxOutputTokens: Int, apiKey: String) async throws -> RequestyCompletion {
        guard let modelID = RequestyValidation.modelID(modelID), maxOutputTokens > 0,
              maxOutputTokens <= 1_000_000, !system.isEmpty else { throw RequestyError.invalidConfiguration }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RequestyError.emptyResponse }
        guard system.utf8.count <= Self.maximumCompletionBytes,
              text.utf8.count <= Self.maximumCompletionBytes else { throw RequestyError.tooLarge }
        var request = try makeRequest(path: "/chat/completions", apiKey: apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = CompletionBody(model: modelID, messages: [.init(role: "system", content: system), .init(role: "user", content: text)], maxTokens: maxOutputTokens)
        request.httpBody = try JSONEncoder().encode(body)
        guard request.httpBody!.count <= Self.maximumCompletionBytes else { throw RequestyError.tooLarge }
        let data = try await perform(request, maximumBytes: Self.maximumCompletionBytes)
        do {
            let response = try JSONDecoder().decode(CompletionEnvelope.self, from: data)
            guard response.choices.count == 1, let choice = response.choices.first,
                  choice.message.role == "assistant", choice.message.toolCalls?.isEmpty != false,
                  choice.message.functionCall == nil, choice.message.refusal == nil else { throw RequestyError.invalidResponse }
            guard choice.finishReason == "stop" else { throw RequestyError.incompleteResponse }
            guard let content = choice.message.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RequestyError.emptyResponse }
            guard !content.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else { throw RequestyError.invalidResponse }
            try Task.checkCancellation()
            return RequestyCompletion(sessionID: sessionID, text: content)
        } catch is CancellationError { throw CancellationError() }
        catch let error as RequestyError { throw error }
        catch { throw RequestyError.invalidResponse }
    }

    private func makeRequest(path: String, apiKey: String) throws -> URLRequest {
        guard let key = RequestyValidation.apiKey(apiKey) else { throw RequestyError.invalidConfiguration }
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = "GET"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse,
                  http.url?.scheme == "https", http.url?.host == "router.requesty.ai",
                  http.url?.path == request.url?.path else { throw RequestyError.invalidResponse }
            let responseLimit = http.statusCode == 200 ? maximumBytes : 65_536
            guard response.expectedContentLength <= responseLimit else { throw RequestyError.tooLarge }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 32_768))
            for try await byte in bytes {
                guard data.count < responseLimit else { throw RequestyError.tooLarge }
                data.append(byte)
                if data.count % 4_096 == 0 { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            switch http.statusCode {
            case 200: return data
            case 300..<400: throw RequestyError.redirectRejected
            case 401: throw RequestyError.unauthorized
            case 402: throw RequestyError.insufficientCredits
            case 403:
                // Requesty documents router auth failures as 403. Provider/RBAC
                // 403s are distinct; only this exact known router message is auth.
                let detail = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
                if detail?.error.origin == "router", detail?.error.message == "Invalid authorization token" {
                    throw RequestyError.unauthorized
                }
                throw RequestyError.forbidden
            case 404: throw RequestyError.modelUnavailable
            case 408, 503, 504: throw RequestyError.timeout
            case 412: throw RequestyError.spendingLimit
            case 413: throw RequestyError.tooLarge
            case 424: throw RequestyError.invalidResponse
            case 429: throw RequestyError.rateLimited
            case 500..<600: throw RequestyError.server
            default: throw RequestyError.invalidResponse
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as RequestyError { throw error }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw RequestyError.timeout }
            throw RequestyError.network
        } catch { if Task.isCancelled { throw CancellationError() }; throw RequestyError.network }
    }
}

final class RequestyRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct ModelEnvelope: Decodable { let data: [RemoteModel] }
private struct RemoteModel: Decodable {
    let id: String
    let api: String?
    let contextWindow: Int?
    let maxOutputTokens: Int?
    let outputModalities: [String]?
    enum CodingKeys: String, CodingKey {
        case id, api
        case contextWindow = "context_window", maxOutputTokens = "max_output_tokens", outputModalities = "output_modalities"
    }
}
private struct CompletionBody: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
    let maxTokens: Int
    let stream = false
    enum CodingKeys: String, CodingKey { case model, messages, stream; case maxTokens = "max_tokens" }
}
private struct CompletionEnvelope: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String?
            let toolCalls: [IgnoredJSON]?
            let functionCall: IgnoredJSON?
            let refusal: String?
            enum CodingKeys: String, CodingKey { case role, content, refusal; case toolCalls = "tool_calls", functionCall = "function_call" }
        }
        let message: Message
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
    }
    let choices: [Choice]
}
private struct IgnoredJSON: Decodable { init(from decoder: Decoder) throws {} }

private struct ErrorEnvelope: Decodable { struct Detail: Decodable { let origin: String?; let message: String? }; let error: Detail }
