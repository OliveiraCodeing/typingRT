import Foundation
import Testing
@testable import TypingRTCore

@Suite(.serialized)
struct RequestyClientTests {
    private let key = "synthetic-unit-test-value"

    @Test func listsOnlyChatModelsAndAuthenticatesWithoutPersistingCookies() async throws {
        let fixture = #"{"data":[{"id":"vendor/b","api":"chat","context_window":128000,"max_output_tokens":4096},{"id":"vendor/a","api":"chat"},{"id":"vendor/b","api":"chat"},{"id":"vendor/embed","api":"embeddings"},{"id":"vendor/unknown"},{"id":"vendor/image","api":"chat","output_modalities":["image"]}]}"#
        let state = ProtocolState.shared
        state.configure { request in
            #expect(request.url?.absoluteString == "https://router.requesty.ai/v1/models")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-unit-test-value")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return .response(200, Data(fixture.utf8))
        }
        let models = try await client().models(apiKey: key)
        #expect(models.map(\.id) == ["vendor/a", "vendor/b"])
        #expect(models[1].contextWindow == 128000)
        #expect(models[1].maxOutputTokens == 4096)
        #expect(state.count == 1)
    }

    @Test func completionContainsOnlyTextContractAndRetainsSessionID() async throws {
        let id = UUID()
        ProtocolState.shared.configure { request in
            #expect(request.url?.absoluteString == "https://router.requesty.ai/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try #require(request.httpBody ?? request.httpBodyStream.flatMap(read))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(Set(json.keys) == ["model", "messages", "max_tokens", "stream", "reasoning_effort"])
            #expect(json["reasoning_effort"] as? String == "none")
            #expect(json["model"] as? String == "vendor/manual")
            #expect(json["stream"] as? Bool == false)
            #expect(json["max_tokens"] as? Int == 1024)
            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages == [["role": "system", "content": "Format the text."], ["role": "user", "content": "Eine synthetische Eingabe."]])
            return .response(200, completion("The formatted input."))
        }
        let result = try await client().complete(sessionID: id, modelID: "vendor/manual", system: "Format the text.", text: "Eine synthetische Eingabe.", maxOutputTokens: 1024, apiKey: key)
        #expect(result == RequestyCompletion(sessionID: id, text: "The formatted input."))
        #expect(ProtocolState.shared.count == 1)
    }

    @Test func mapsFailuresToFixedMessagesAndNeverRetries() async throws {
        let cases: [(Int, String, RequestyError)] = [
            (401, "private response", .unauthorized), (402, "", .insufficientCredits),
            (403, #"{"error":{"origin":"router","message":"Invalid authorization token"}}"#, .unauthorized),
            (403, #"{"error":{"origin":"provider","message":"Invalid authorization token"}}"#, .forbidden),
            (403, "private response", .forbidden), (404, "", .modelUnavailable), (408, "", .timeout),
            (412, "", .spendingLimit), (413, "", .tooLarge), (424, "", .invalidResponse), (429, "", .rateLimited),
            (500, "", .server), (503, "", .timeout), (504, "", .timeout), (302, "", .redirectRejected)]
        for (status, body, expected) in cases {
            ProtocolState.shared.configure { _ in .response(status, Data(body.utf8)) }
            do { _ = try await client().models(apiKey: key); Issue.record("Expected failure") }
            catch let error as RequestyError { #expect(error == expected); #expect(!error.localizedDescription.contains("private response")) }
            #expect(ProtocolState.shared.count == 1)
        }
    }

    @Test func timeoutAndNetworkErrorsAreSanitized() async throws {
        for (code, expected) in [(URLError.timedOut, RequestyError.timeout), (.notConnectedToInternet, .network)] {
            ProtocolState.shared.configure { _ in .failure(URLError(code, userInfo: [NSLocalizedDescriptionKey: "sensitive-response"])) }
            do { _ = try await client().models(apiKey: key); Issue.record("Expected error") }
            catch let error as RequestyError { #expect(error == expected); #expect(!error.localizedDescription.contains("sensitive-response")) }
            #expect(ProtocolState.shared.count == 1)
        }
    }

    @Test func rejectsEmptyTruncatedToolAndMalformedResponses() async throws {
        let bodies: [(Data, RequestyError)] = [
            (completion(""), .emptyResponse), (completion("partial", finish: "length"), .incompleteResponse),
            (completion("text", finish: "tool_calls"), .incompleteResponse),
            (Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"text","tool_calls":[{}]}}]}"#.utf8), .invalidResponse),
            (Data("{}".utf8), .invalidResponse), (Data("not-json".utf8), .invalidResponse)]
        for (body, expected) in bodies {
            ProtocolState.shared.configure { _ in .response(200, body) }
            do { _ = try await client().complete(sessionID: UUID(), modelID: "vendor/model", system: "System", text: "Text", maxOutputTokens: 128, apiKey: key); Issue.record("Expected error") }
            catch let error as RequestyError { #expect(error == expected) }
        }
    }

    @Test func boundsIncomingAndOutgoingBodies() async throws {
        ProtocolState.shared.configure { _ in .response(200, Data(repeating: 32, count: RequestyClient.maximumModelsBytes + 1)) }
        await #expect(throws: RequestyError.tooLarge) { _ = try await client().models(apiKey: key) }
        #expect(ProtocolState.shared.count == 1)
        ProtocolState.shared.configure { _ in .response(200, Data()) }
        await #expect(throws: RequestyError.tooLarge) {
            _ = try await client().complete(sessionID: UUID(), modelID: "vendor/model", system: "System", text: String(repeating: "a", count: RequestyClient.maximumCompletionBytes + 1), maxOutputTokens: 10, apiKey: key)
        }
        #expect(ProtocolState.shared.count == 0)
    }

    @Test func cancellationCancelsTransportAndDiscardsLateCompletion() async throws {
        ProtocolState.shared.configure { _ in .wait }
        let service = client()
        let task = Task { try await service.models(apiKey: key) }
        for _ in 0..<100 where ProtocolState.shared.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ProtocolState.shared.count == 1)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled response delivered") }
        catch { #expect(error is CancellationError) }
        #expect(ProtocolState.shared.count == 1)
    }

    @Test func redirectDelegateRejectsSameAndOtherHost() async throws {
        let delegate = RequestyRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://router.requesty.ai/v1/models")!)
        for host in ["router.requesty.ai", "untrusted.invalid"] {
            let redirect = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
            let decision = LockedDecision()
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "https://\(host)/redirect")!)) { decision.set($0) }
            #expect(decision.wasCalled)
            #expect(decision.request == nil)
        }
    }

    @Test func invalidConfigurationDoesNotContactNetwork() async throws {
        ProtocolState.shared.configure { _ in .response(200, Data()) }
        await #expect(throws: RequestyError.invalidConfiguration) { _ = try await client().models(apiKey: "  ") }
        await #expect(throws: RequestyError.invalidConfiguration) { _ = try await client().models(apiKey: "key\r\nInjected: value") }
        await #expect(throws: RequestyError.invalidConfiguration) {
            _ = try await client().complete(sessionID: UUID(), modelID: " \n ", system: "System", text: "Text", maxOutputTokens: 10, apiKey: key)
        }
        #expect(ProtocolState.shared.count == 0)
        #expect(RequestyValidation.modelID(" vendor/manual ") == "vendor/manual")
        #expect(RequestyValidation.modelID("vendor/bad\nmodel") == nil)
    }

    private func client() -> RequestyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestyTestProtocol.self]
        return RequestyClient(configuration: config)
    }
}

private func completion(_ text: String, finish: String = "stop") -> Data {
    try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": ["role": "assistant", "content": text]]]])
}

private func read(_ stream: InputStream) -> Data? {
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }; if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

private final class LockedDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var value: URLRequest?
    func set(_ request: URLRequest?) { lock.withLock { called = true; value = request } }
    var wasCalled: Bool { lock.withLock { called } }
    var request: URLRequest? { lock.withLock { value } }
}

private final class ProtocolState: @unchecked Sendable {
    enum Reply { case response(Int, Data), failure(URLError), wait }
    static let shared = ProtocolState()
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> Reply)?
    private var requests = 0
    var count: Int { lock.withLock { requests } }
    func configure(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) {
        lock.withLock { self.handler = handler; requests = 0 }
    }
    func reply(_ request: URLRequest) throws -> Reply {
        let callback = lock.withLock { requests += 1; return handler }
        return try callback!(request)
    }
}

private final class RequestyTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            switch try ProtocolState.shared.reply(request) {
            case .response(let code, let data):
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for offset in stride(from: 0, to: data.count, by: 16_384) {
                    client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(data.count, offset + 16_384)))
                }
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
            case .wait: break
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
