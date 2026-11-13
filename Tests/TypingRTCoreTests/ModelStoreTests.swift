import Foundation
import Testing
@testable import TypingRTCore

@MainActor
struct ModelStoreTests {
    @Test
    func initializationAndRefreshNeverStartAnInstallation() async {
        let installer = StoreTestInstaller()
        let store = LocalModelStore(installer: installer, catalog: ModelCatalog.models)
        #expect(store.state == .notChecked)
        #expect(store.installedPath == nil)
        #expect(await installer.installations == 0)

        await store.refresh()

        #expect(store.state == .missing)
        #expect(!store.isBusy)
        #expect(store.installedPath == nil)
        #expect(store.tokenizerPath == nil)
        #expect(await installer.installations == 0)
        #expect(await installer.refreshes == 1)
    }

    @Test
    func explicitInstallationPublishesPathsAndPinnedManifest() async {
        let installer = StoreTestInstaller()
        let store = LocalModelStore(installer: installer, catalog: ModelCatalog.models)
        await store.install()

        #expect(store.state == .installed)
        #expect(store.progress == 1)
        #expect(store.installedPath?.lastPathComponent == "model")
        #expect(store.tokenizerPath?.lastPathComponent == "tokenizer")
        #expect(store.installedManifest?.descriptor == ModelCatalog.compressedTurbo)
        #expect(await installer.installations == 1)
        #expect(store.error == nil)
    }

    @Test
    func installationFailureDoesNotClaimAnInstalledModel() async {
        let installer = StoreTestInstaller(fail: true)
        let store = LocalModelStore(installer: installer, catalog: ModelCatalog.models)
        await store.install()

        #expect(store.state == .failed)
        #expect(store.installedPath == nil)
        #expect(store.installedManifest == nil)
        #expect(store.error != nil)
        #expect(!store.isBusy)
    }
}

private actor StoreTestInstaller: ModelInstallerProtocol {
    let fail: Bool
    private(set) var installations = 0
    private(set) var refreshes = 0

    init(fail: Bool = false) { self.fail = fail }

    func installedModel(for descriptor: ModelDescriptor) async throws -> InstalledModel? {
        refreshes += 1
        return nil
    }

    func install(
        _ descriptor: ModelDescriptor, progress: @escaping @Sendable (ModelInstallProgress) -> Void
    ) async throws -> InstalledModel {
        installations += 1
        if fail { throw ModelInstallationError.invalidResponse }
        progress(ModelInstallProgress(phase: .downloading, completedBytes: 1, totalBytes: 2))
        let assets = [InstalledModelAsset(path: "synthetic", byteCount: 0, sha256: String(repeating: "0", count: 64))]
        let manifest = InstalledModelManifest(
            schemaVersion: 1, installationID: UUID(), descriptor: descriptor,
            installedAt: Date(), assets: assets, inventorySHA256: "synthetic-test-only"
        )
        return InstalledModel(manifest: manifest, directory: URL(fileURLWithPath: "/synthetic-model-test"))
    }
}
