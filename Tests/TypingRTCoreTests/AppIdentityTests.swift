import Foundation
import Testing
@testable import TypingRTCore

struct AppIdentityTests {
    @Test func productAndDevelopmentDomainsAreIndependent() {
        let home = URL(fileURLWithPath: "/test/home")
        let product = AppIdentity(identifier: "dev.typingrt.mac", homeDirectory: home)
        let development = AppIdentity(identifier: "dev.typingrt.mac.development", homeDirectory: home)
        let preview = AppIdentity(identifier: "dev.typingrt.mac.preview", homeDirectory: home)
        #expect(Set([product, development, preview].map(\.applicationSupport)).count == 3)
        #expect(Set([product, development, preview].map(\.namespace)).count == 3)
        #expect(Set([product, development, preview].map(\.workerServiceName)).count == 3)
        #expect(Set([product, development, preview].map(\.keychainService)).count == 3)
        #expect(product.applicationSupport.path == "/test/home/Library/Application Support/typingRT")
        #expect(development.workerServiceName == "dev.typingrt.mac.development.TranscriptionWorker")
    }

    @Test func smokeUsesTemporaryDataAndProcessSpecificNamespace() {
        let temporary = URL(fileURLWithPath: "/test/temp")
        let smoke = AppIdentity(identifier: "dev.typingrt.mac.development", smokeSession: "123", temporaryDirectory: temporary)
        let other = AppIdentity(identifier: "dev.typingrt.mac.development", smokeSession: "456", temporaryDirectory: temporary)
        #expect(smoke.applicationSupport.path == "/test/temp/dev.typingrt.mac.development.smoke.123")
        #expect(smoke.applicationSupport != other.applicationSupport)
        #expect(smoke.namespace != other.namespace)
    }
}
