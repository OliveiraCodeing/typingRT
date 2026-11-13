import Foundation
import Observation

public enum LocalModelState: Sendable, Equatable {
    case notChecked
    case checking
    case missing
    case downloading
    case verifying
    case activating
    case installed
    case cancelling
    case failed
}

@MainActor
@Observable
public final class LocalModelStore {
    public let catalog: [ModelDescriptor]
    public var selectedID: String {
        didSet {
            guard selectedID != oldValue else { return }
            if isBusy { selectedID = oldValue; return }
            installedPath = nil
            tokenizerPath = nil
            installedManifest = nil
            state = .notChecked
            error = nil
        }
    }
    public private(set) var state: LocalModelState = .notChecked
    public private(set) var progress: Double = 0
    public private(set) var error: String?
    public private(set) var installedPath: URL?
    public private(set) var tokenizerPath: URL?
    public private(set) var installedManifest: InstalledModelManifest?

    @ObservationIgnored private let installer: any ModelInstallerProtocol
    @ObservationIgnored private var installTask: Task<InstalledModel, Error>?
    @ObservationIgnored private var operationID: UUID?

    public convenience init(rootURL: URL = ModelCatalog.defaultRoot) {
        self.init(installer: ModelInstaller(rootURL: rootURL), catalog: ModelCatalog.models)
    }

    init(installer: any ModelInstallerProtocol, catalog: [ModelDescriptor]) {
        self.installer = installer
        self.catalog = catalog
        selectedID = catalog.first?.id ?? ""
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .activating, .cancelling: true
        default: false
        }
    }

    public var canCancel: Bool { installTask != nil }

    public func shutdown() async {
        installTask?.cancel()
        _ = try? await installTask?.value
    }

    public var status: String {
        switch state {
        case .notChecked: "Lokales Modell noch nicht geprüft"
        case .checking: "Lokales Modell wird geprüft"
        case .missing: "Lokales Modell fehlt"
        case .downloading: "Modell wird heruntergeladen"
        case .verifying: "Modelldateien werden geprüft"
        case .activating: "Modellinstallation wird abgeschlossen"
        case .installed: "Lokales Modell installiert"
        case .cancelling: "Download wird abgebrochen"
        case .failed: "Modell ist nicht einsatzbereit"
        }
    }

    /// Explicit local validation only. This method never requests network data.
    public func refresh() async {
        guard !isBusy, let descriptor = catalog.first(where: { $0.id == selectedID }) else { return }
        let operation = UUID()
        operationID = operation
        state = .checking
        error = nil
        do {
            let result = try await installer.installedModel(for: descriptor)
            guard operationID == operation else { return }
            apply(result)
        } catch {
            guard operationID == operation else { return }
            clearPaths()
            state = .failed
            self.error = "Die lokale Installation konnte nicht bestätigt werden. Bitte erneut installieren."
        }
    }

    public func install() async {
        guard !isBusy, let descriptor = catalog.first(where: { $0.id == selectedID }) else { return }
        let previous = currentInstallation
        let operation = UUID()
        operationID = operation
        error = nil
        progress = 0
        state = .downloading
        let installer = self.installer
        let task = Task { [weak self] in
            try await installer.install(descriptor) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.operationID == operation, self.state != .cancelling, self.installTask != nil else { return }
                    self.progress = event.fraction
                    switch event.phase {
                    case .resolving, .downloading: self.state = .downloading
                    case .verifying: self.state = .verifying
                    case .activating: self.state = .activating
                    }
                }
            }
        }
        installTask = task
        do {
            let installed = try await task.value
            guard operationID == operation else { return }
            installTask = nil
            apply(installed)
        } catch is CancellationError {
            guard operationID == operation else { return }
            installTask = nil
            apply(previous)
        } catch {
            guard operationID == operation else { return }
            installTask = nil
            apply(previous)
            state = .failed
            self.error = "Der Modell-Download ist fehlgeschlagen. Bitte Verbindung und freien Speicher prüfen oder erneut versuchen."
        }
    }

    public func cancel() {
        guard let installTask else { return }
        state = .cancelling
        installTask.cancel()
    }

    private var currentInstallation: InstalledModel? {
        guard let manifest = installedManifest, let path = installedPath else { return nil }
        return InstalledModel(manifest: manifest, directory: path.deletingLastPathComponent())
    }

    private func apply(_ installation: InstalledModel?) {
        if let installation {
            installedPath = installation.modelPath
            tokenizerPath = installation.tokenizerPath
            installedManifest = installation.manifest
            progress = 1
            state = .installed
        } else {
            clearPaths()
            progress = 0
            state = .missing
        }
    }

    private func clearPaths() {
        installedPath = nil
        tokenizerPath = nil
        installedManifest = nil
    }
}
