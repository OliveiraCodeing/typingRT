import AppKit
import Darwin
import SwiftUI
import TypingRTCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = InstanceLock()
    private let captureOwnership = InstanceLock()
    private var window: NSWindow?
    private(set) var statusItem: NSStatusItem?
    private(set) var model: AppModel?
    private let showWindowNotification = Notification.Name(AppIdentity.current.namespace + ".showWindow")
    private let smokeTest = CommandLine.arguments.contains("--smoke-test")
    private var smokeDefaults: UserDefaults?
    private var overlay: DictationOverlay?
    private var terminationPending = false
    private var terminationReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.make()
        do {
            let launch = LaunchPolicy(
                isLoginLaunch: LaunchPolicy.isCurrentLoginLaunch(), isSmokeTest: smokeTest,
                explicitWindow: CommandLine.arguments.contains("--show-window"),
                hasOpened: UserDefaults.standard.bool(forKey: "typingRT.hasOpened"))
            let namespace = AppIdentity.current.namespace
            guard try instanceLock.acquire(namespace: namespace) else {
                if launch.shouldNotifyExistingInstance {
                    DistributedNotificationCenter.default().postNotificationName(showWindowNotification,
                        object: AppIdentity.current.namespace, userInfo: nil, deliverImmediately: true)
                }
                NSApp.terminate(nil)
                return
            }
            if smokeTest {
                let suite = AppIdentity.current.namespace
                guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.coderInvalidValue) }
                smokeDefaults = defaults
                defaults.removePersistentDomain(forName: suite)
                model = AppModel(preferences: PreferencesStore(defaults: defaults), nativeMonitoringEnabled: false)
            } else {
                // The unchanged daily baseline owns the legacy instance lock. Reuse
                // that lock so two independently installed builds cannot hear one hold.
                let mayCapture = AppIdentity.current.identifier == "dev.typingrt.mac"
                    ? true : try captureOwnership.acquire(namespace: "dev.typingrt.mac")
                model = AppModel(nativeDictationAllowed: mayCapture)
            }
            if let model, !smokeTest { overlay = DictationOverlay(controller: model.dictation, selectMode: { [weak model] in model?.selectedMode = $0 }) }
            model?.onChange = { [weak self] in
                self?.updateMenu()
                self?.overlay?.refresh()
            }
            installMenu()
            overlay?.refresh()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(interruptForSystem),
                                                               name: NSWorkspace.willSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(interruptForSystem),
                                                               name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveShowWindow),
                                                                 name: showWindowNotification, object: AppIdentity.current.namespace)
            if launch.shouldShowMainWindow {
                showMainWindow()
                if !smokeTest { UserDefaults.standard.set(true, forKey: "typingRT.hasOpened") }
            }
            if smokeTest { beginSmokeTest() }
        } catch {
            if smokeTest {
                writeSmokeFailure("Start fehlgeschlagen: \(error.localizedDescription)")
                finishSmokeTest(exitCode: 1)
            } else {
                let alert = NSAlert()
                alert.messageText = "typingRT konnte nicht starten"
                alert.informativeText = "Die lokale App-Instanz konnte nicht eingerichtet werden. \(error.localizedDescription)"
                alert.runModal()
            }
            NSApp.terminate(nil)
        }
    }

    private func installMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "typingRT")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "typingRT"
        updateMenu()
    }

    private func updateMenu() {
        guard let model, let statusItem else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: model.statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if model.coding.phase == .awaitingDecision {
            let retry = NSMenuItem(title: "Coding erneut versuchen", action: #selector(retryCoding), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
            let original = NSMenuItem(title: "Lokales Original kopieren", action: #selector(copyOriginal), keyEquivalent: "")
            original.target = self
            menu.addItem(original)
            let discard = NSMenuItem(title: "Diktat verwerfen", action: #selector(discardCoding), keyEquivalent: "")
            discard.target = self
            menu.addItem(discard)
        }
        if model.delivery.phase == .awaitingResult {
            let copy = NSMenuItem(title: "Ergebnis kopieren", action: #selector(copyResult), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            let discard = NSMenuItem(title: "Ergebnis verwerfen", action: #selector(discardResult), keyEquivalent: "")
            discard.target = self
            menu.addItem(discard)
        }
        menu.addItem(.separator())
        for mode in DictationMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.target = self
            item.state = model.selectedMode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let show = NSMenuItem(title: "typingRT öffnen", action: #selector(showMainWindow), keyEquivalent: ",")
        show.target = self
        menu.addItem(show)
        let quit = NSMenuItem(title: "typingRT beenden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        if model.dictation.isBusy {
            let next = NSMenuItem(title: "Moduswechsel gilt ab nächstem Diktat", action: nil, keyEquivalent: "")
            next.isEnabled = false
            menu.insertItem(next, at: min(1, menu.items.count))
        }
        statusItem.button?.setAccessibilityLabel("typingRT · \(model.statusTitle) · \(model.selectedMode.title)")
        statusItem.menu = menu
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let mode = DictationMode(rawValue: value) else { return }
        model?.selectedMode = mode
    }

    @objc private func retryCoding() {
        guard let id = model?.coding.original?.sessionID else { return }
        model?.coding.retry(sessionID: id)
    }

    @objc private func copyOriginal() {
        guard let id = model?.coding.original?.sessionID else { return }
        model?.coding.takeOriginal(sessionID: id)
    }

    @objc private func discardCoding() { model?.dictation.abort(message: "Diktat verworfen.") }

    @objc private func copyResult() {
        guard let id = model?.delivery.result?.sessionID else { return }
        model?.delivery.copy(sessionID: id)
    }

    @objc private func discardResult() {
        guard let id = model?.delivery.result?.sessionID else { return }
        model?.delivery.discard(sessionID: id)
    }

    @objc func showMainWindow() {
        guard let model else { return }
        model.refreshPermissions()
        if window == nil {
            let view = RootView(model: model)
            let host = NSHostingController(rootView: view)
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: AppTheme.windowSize.width, height: AppTheme.windowSize.height),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            created.title = "typingRT"
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.backgroundColor = NSColor(red: 18 / 255, green: 20 / 255, blue: 22 / 255, alpha: 1)
            created.contentViewController = host
            created.minSize = AppTheme.minimumWindowSize
            created.appearance = NSAppearance(named: .darkAqua)
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func receiveShowWindow(_ notification: Notification) { showMainWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func interruptForSystem(_ notification: Notification) {
        model?.interruptForSystem()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refreshPermissions()
        if !smokeTest { Task { [weak self] in await self?.model?.loginItem.refresh() } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        model?.shutDown()
        overlay?.hide()
        Task { [weak self] in
            await self?.model?.finishShutdown()
            self?.replyToTermination()
        }
        // Hardware teardown must never keep the UI or process alive indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.replyToTermination() }
        return .terminateLater
    }

    private func replyToTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanUp()
    }

    private func cleanUp() {
        model?.shutDown()
        overlay?.hide()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        DistributedNotificationCenter.default().removeObserver(self)
        if smokeTest {
            smokeDefaults?.removePersistentDomain(forName: AppIdentity.current.namespace)
        }
    }

    // Explicit local verification mode: isolated preferences, no permission prompts or audio.
    private func beginSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.runSmokeChecks()
        }
    }

    private func runSmokeChecks() {
        do {
            guard let model, let window, let content = window.contentView, let menu = statusItem?.menu else {
                throw SmokeFailure("Fenster oder Menü fehlt")
            }
            guard model.selectedMode == .standard, !model.readiness.canStart else { throw SmokeFailure("Falscher Erstzustand") }
            model.selectedMode = .coding
            guard statusItem?.menu?.items.contains(where: { $0.title == "Coding" && $0.state == .on }) == true else {
                throw SmokeFailure("Moduswahl im Menü nicht synchron")
            }
            model.selectedMode = .standard
            guard !menu.items.contains(where: { $0.title.contains("Aufnahme starten") }) else { throw SmokeFailure("Aufnahme-Toggle vorhanden") }
            window.close()
            guard !window.isVisible, !applicationShouldTerminateAfterLastWindowClosed(NSApp) else { throw SmokeFailure("Fenster-Lebenszyklus fehlerhaft") }
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            content.layoutSubtreeIfNeeded()
            if let output = argument(after: "--snapshot") {
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw SmokeFailure("Snapshot fehlgeschlagen") }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SmokeFailure("PNG fehlgeschlagen") }
                try png.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            let checkLock = InstanceLock()
            let lockNamespace = "dev.typingrt.mac.check.\(ProcessInfo.processInfo.processIdentifier)"
            guard try checkLock.acquire(namespace: lockNamespace),
                  try !InstanceLock().acquire(namespace: lockNamespace) else { throw SmokeFailure("Single-Instance-Sperre fehlerhaft") }
            model.shutDown()
            let report: [String: Any] = [
                "passed": true, "windowReopened": window.isVisible, "modeMenuSynchronized": true,
                "singleInstanceLock": true, "microphone": String(describing: model.microphone),
                "accessibilityGranted": model.accessibilityGranted, "dictationAvailable": false,
                "permissionRequestsMade": false, "networkRequestsMade": false
            ]
            try writeSmokeReport(report)
        } catch {
            writeSmokeFailure(error.localizedDescription)
            finishSmokeTest(exitCode: 1)
        }
        finishSmokeTest(exitCode: 0)
    }

    private func argument(after name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private func writeSmokeReport(_ report: [String: Any]) throws {
        guard let path = argument(after: "--report") else { throw SmokeFailure("Fehlender --report-Pfad") }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func writeSmokeFailure(_ message: String) {
        FileHandle.standardError.write(Data("typingRT-Prüfung fehlgeschlagen: \(message)\n".utf8))
        do { try writeSmokeReport(["passed": false, "error": message]) }
        catch { FileHandle.standardError.write(Data("Prüfbericht konnte nicht geschrieben werden: \(error.localizedDescription)\n".utf8)) }
    }

    private func finishSmokeTest(exitCode: Int32) -> Never {
        cleanUp()
        Darwin.exit(exitCode)
    }
}

private struct SmokeFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
