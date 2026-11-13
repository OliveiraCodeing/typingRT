import Foundation
import Testing
@testable import TypingRTCore

struct RequestyCredentialsTests {
    @Test func savesReadsReplacesAndDeletesThroughOnlyTheBackend() async throws {
        let backend = MemoryCredentialBackend()
        let store = RequestyCredentials(service: "synthetic.tests", backend: backend)
        #expect(try await store.read() == nil)
        try await store.save("  synthetic-credential-A  ")
        #expect(try await store.read() == "synthetic-credential-A")
        let reloaded = RequestyCredentials(service: "synthetic.tests", backend: backend)
        #expect(try await reloaded.read() == "synthetic-credential-A")
        try await reloaded.save("synthetic-credential-B")
        #expect(try await store.read() == "synthetic-credential-B")
        try await reloaded.delete()
        try await reloaded.delete()
        #expect(try await store.read() == nil)
        #expect(backend.services == Set(["synthetic.tests"]))
        #expect(!backend.usedMainThread)
    }

    @Test func emptyAndMalformedInputNeverOverwritesAnExistingCredential() async throws {
        let backend = MemoryCredentialBackend()
        let store = RequestyCredentials(service: "synthetic.tests", backend: backend)
        try await store.save("synthetic-credential-A")
        for invalid in ["", " \n\t ", "interior whitespace", "line\nfeed", "unicode-ä", String(repeating: "a", count: 8_193)] {
            await #expect(throws: RequestyCredentialError.invalidKey) { try await store.save(invalid) }
            #expect(try await store.read() == "synthetic-credential-A")
        }
    }

    @Test func failedSavePreservesPreviousCredentialAndErrorsAreSanitized() async throws {
        let backend = MemoryCredentialBackend()
        let store = RequestyCredentials(service: "synthetic.tests", backend: backend)
        try await store.save("synthetic-credential-A")
        backend.failure = true
        await #expect(throws: RequestyCredentialError.unavailable) { try await store.save("synthetic-credential-B") }
        await #expect(throws: RequestyCredentialError.unavailable) { try await store.read() }
        await #expect(throws: RequestyCredentialError.unavailable) { try await store.delete() }
        backend.failure = false
        #expect(try await store.read() == "synthetic-credential-A")
        #expect(!RequestyCredentialError.unavailable.localizedDescription.contains("private-backend-detail"))
    }

    @Test func malformedStoredValuesAreRejectedWithoutAnUnprotectedFallback() async throws {
        let backend = MemoryCredentialBackend()
        let store = RequestyCredentials(service: "synthetic.tests", backend: backend)
        for invalid in [Data([0xff]), Data("".utf8), Data(" padded ".utf8), Data(repeating: 65, count: 8_193)] {
            try backend.save(invalid, service: "synthetic.tests")
            await #expect(throws: RequestyCredentialError.invalidStoredKey) { try await store.read() }
        }
    }

    @Test func serviceDomainsAreIndependent() async throws {
        let backend = MemoryCredentialBackend()
        let first = RequestyCredentials(service: "synthetic.daily.Requesty", backend: backend)
        let second = RequestyCredentials(service: "synthetic.development.Requesty", backend: backend)
        try await first.save("synthetic-credential-A")
        #expect(try await second.read() == nil)
        try await second.save("synthetic-credential-B")
        try await first.delete()
        #expect(try await second.read() == "synthetic-credential-B")
    }

    @Test func cancelledOperationDoesNotReachTheBackend() async throws {
        let backend = MemoryCredentialBackend()
        let store = RequestyCredentials(service: "synthetic.tests", backend: backend)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.save("synthetic-credential-A")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(backend.services.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPINGRT_RUN_KEYCHAIN_TESTS"] == "1"))
    func nativeKeychainRoundTripWithIsolatedSyntheticEntry() async throws {
        let service = "dev.typingrt.tests.Requesty.\(UUID().uuidString)"
        let first = RequestyCredentials(service: service)
        do {
            try await first.save("synthetic-keychain-fixture")
            let second = RequestyCredentials(service: service)
            #expect(try await second.read() == "synthetic-keychain-fixture")
            try await second.delete()
            #expect(try await first.read() == nil)
        } catch {
            try? await first.delete()
            throw error
        }
    }
}

private final class MemoryCredentialBackend: RequestyCredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var touched: Set<String> = []
    private var sawMainThread = false
    private var shouldFail = false

    var services: Set<String> { lock.withLock { touched } }
    var usedMainThread: Bool { lock.withLock { sawMainThread } }
    var failure: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }

    private func touch(_ service: String) throws {
        touched.insert(service)
        sawMainThread = sawMainThread || Thread.isMainThread
        if shouldFail { throw NSError(domain: "private-backend-detail", code: 1) }
    }
    func read(service: String) throws -> Data? {
        try lock.withLock { try touch(service); return values[service] }
    }
    func save(_ data: Data, service: String) throws {
        try lock.withLock { try touch(service); values[service] = data }
    }
    func delete(service: String) throws {
        try lock.withLock { try touch(service); values[service] = nil }
    }
}
