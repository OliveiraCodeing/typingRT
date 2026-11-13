import AppKit
import CoreServices
import Testing

@testable import TypingRTApp

private actor LoginItemDouble: LoginItemServing {
    var current: LoginItemStatus = .notRegistered
    var requests: [Bool] = []
    var settingsCount = 0
    var fail = false
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?

    func status() -> LoginItemStatus { current }
    func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus {
        requests.append(enabled)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if fail { throw CocoaError(.fileReadNoPermission) }
        current = enabled ? .enabled : .notRegistered
        return current
    }
    func openSettings() { settingsCount += 1 }
    func configure(_ status: LoginItemStatus, fail: Bool = false, hold: Bool = false) {
        current = status
        self.fail = fail
        self.hold = hold
    }
    func waiting() -> Bool { continuation != nil }
    func release() {
        hold = false
        continuation?.resume()
        continuation = nil
    }
    func requested() -> [Bool] { requests }
    func openedSettings() -> Int { settingsCount }
}

@MainActor
struct LoginItemTests {
    @Test func constructionAndRefreshDoNotRegisterAndUseNativeState() async {
        let service = LoginItemDouble()
        let controller = LoginItemController(service: service)
        #expect(!controller.isLoaded)
        #expect(await service.requested().isEmpty)
        await controller.setEnabled(true)
        #expect(await service.requested().isEmpty)
        await controller.refresh()
        #expect(controller.isLoaded && controller.status == .notRegistered)
        await service.configure(.enabled)
        await controller.refresh()
        #expect(controller.status == .enabled)
        #expect(await service.requested().isEmpty)
    }

    @Test func explicitEnableDisableAndApprovalState() async {
        let service = LoginItemDouble()
        let controller = LoginItemController(service: service)
        await controller.refresh()
        await controller.setEnabled(true)
        #expect(controller.status == .enabled && controller.error == nil)
        await controller.setEnabled(false)
        #expect(controller.status == .notRegistered)
        #expect(await service.requested() == [true, false])
        await service.configure(.requiresApproval)
        await controller.refresh()
        #expect(controller.status.isRegistered)
        await controller.openSettings()
        #expect(await service.openedSettings() == 1)
    }

    @Test func failureRefreshesActualStatusAndDoubleSubmitDoesNotQueue() async {
        let service = LoginItemDouble()
        await service.configure(.requiresApproval, fail: true, hold: true)
        let controller = LoginItemController(service: service)
        await controller.refresh()
        let task = Task { await controller.setEnabled(false) }
        for _ in 0..<1_000 {
            if await service.waiting() { break }
            await Task.yield()
        }
        #expect(await service.waiting())
        #expect(controller.isBusy)
        await controller.setEnabled(true)
        await service.release()
        await task.value
        #expect(await service.requested() == [false])
        #expect(controller.status == .requiresApproval)
        #expect(controller.error != nil && !controller.isBusy)
    }

    @Test func loginAlwaysSuppressesMainWindowAndDuplicateActivation() {
        for first in [false, true] {
            for explicit in [false, true] {
                let login = LaunchPolicy(
                    isLoginLaunch: true, isSmokeTest: false, explicitWindow: explicit, hasOpened: !first)
                #expect(!login.shouldShowMainWindow && !login.shouldNotifyExistingInstance)
            }
        }
        #expect(
            LaunchPolicy(isLoginLaunch: false, isSmokeTest: false, explicitWindow: false, hasOpened: false)
                .shouldShowMainWindow)
        #expect(
            !LaunchPolicy(isLoginLaunch: false, isSmokeTest: false, explicitWindow: false, hasOpened: true)
                .shouldShowMainWindow)
        #expect(
            LaunchPolicy(isLoginLaunch: false, isSmokeTest: false, explicitWindow: true, hasOpened: true)
                .shouldShowMainWindow)
    }

    @Test func onlyNativeOpenApplicationLoginEventMatches() {
        #expect(!LaunchPolicy.isLoginEvent(nil))
        let event = NSAppleEventDescriptor(
            eventClass: kCoreEventClass, eventID: kAEOpenApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        #expect(!LaunchPolicy.isLoginEvent(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        #expect(LaunchPolicy.isLoginEvent(event))
        let unrelated = NSAppleEventDescriptor(
            eventClass: kCoreEventClass, eventID: kAEOpenDocuments,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        unrelated.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        #expect(!LaunchPolicy.isLoginEvent(unrelated))
    }
}
