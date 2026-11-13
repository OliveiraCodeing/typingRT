import SwiftUI

@MainActor
struct LoginItemSettings: View {
    @Bindable var controller: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "Beim Anmelden starten",
                isOn: Binding(
                    get: { controller.status.isRegistered },
                    set: { enabled in Task { await controller.setEnabled(enabled) } }
                )
            )
            .disabled(!controller.isLoaded || controller.isBusy)
            Text(controller.isLoaded ? controller.status.detail : "Anmelde-Start wird geprüft …")
                .font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.status == .requiresApproval || controller.status == .notFound || controller.error != nil {
                Button("Anmeldeobjekte öffnen", systemImage: "arrow.up.forward.square") {
                    Task { await controller.openSettings() }
                }
                .disabled(controller.isBusy)
            }
        }
        .appCard()
        .task { await controller.refresh() }
    }
}
