import Foundation
import Observation
import ServiceManagement

enum LoginItemStatus: Sendable, Equatable {
    case notRegistered, enabled, requiresApproval, notFound

    var isRegistered: Bool { self == .enabled || self == .requiresApproval }

    var detail: String {
        switch self {
        case .notRegistered: "Deaktiviert. typingRT startet nur, wenn du die App öffnest."
        case .enabled: "Aktiviert. Beim Anmelden bleibt typingRT ohne Hauptfenster in der Menüleiste."
        case .requiresApproval: "Registriert, aber von macOS noch nicht freigegeben. Prüfe die Anmeldeobjekte."
        case .notFound: "macOS findet diesen App-Dienst nicht. Öffne das vollständige lokale App-Bundle erneut."
        }
    }
}

protocol LoginItemServing: Sendable {
    func status() async -> LoginItemStatus
    func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus
    func openSettings() async
}

/// ServiceManagement calls run on this executor, never in the UI update path.
/// The native service is created inside the actor; it never crosses isolation.
actor NativeLoginItemService: LoginItemServing {
    func status() -> LoginItemStatus { Self.map(SMAppService.mainApp.status) }

    func setEnabled(_ enabled: Bool) async throws -> LoginItemStatus {
        let service = SMAppService.mainApp
        let current = Self.map(service.status)
        if enabled {
            if !current.isRegistered { try service.register() }
        } else if current != .notRegistered {
            try await service.unregister()
        }
        return Self.map(service.status)
    }

    func openSettings() async {
        await MainActor.run { SMAppService.openSystemSettingsLoginItems() }
    }

    private static func map(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}

@MainActor
@Observable
final class LoginItemController {
    private(set) var status: LoginItemStatus = .notRegistered
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var error: String?
    @ObservationIgnored private let service: any LoginItemServing

    /// Merely constructing or reading the controller never registers a service.
    init(service: any LoginItemServing = NativeLoginItemService()) { self.service = service }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = await service.status()
        isLoaded = true
    }

    func setEnabled(_ enabled: Bool) async {
        guard isLoaded, !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            status = try await service.setEnabled(enabled)
        } catch {
            // The OS remains the authority even if a partially successful call
            // returns an error. Never persist a guessed enabled flag.
            status = await service.status()
            self.error =
                "Anmelde-Start konnte nicht geändert werden. Prüfe die Anmeldeobjekte in den Systemeinstellungen."
        }
    }

    func openSettings() async { await service.openSettings() }
}
