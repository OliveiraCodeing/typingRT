import SwiftUI
import TypingRTCore

@MainActor
struct RequestyView: View {
    @Bindable var settings: RequestySettings
    @Bindable private var editor: RequestyEditor

    init(settings: RequestySettings) {
        self.settings = settings
        self.editor = settings.editor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "network").font(.system(size: 25)).foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Requesty · Coding").font(.system(size: 19, weight: .semibold))
                    Text("Dein Zugang. Dein Textmodell. Standard bleibt vollständig lokal.")
                        .font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                }
            }
            Label(credentialLabel, systemImage: settings.credentialState == .stored ? "lock.shield.fill" : "key")
                .foregroundStyle(AppTheme.accent)
            HStack(spacing: 10) {
                SecureField("Neuen Requesty-Schlüssel eingeben", text: $editor.keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Requesty-Schlüssel, verdeckte Eingabe")
                Button("Speichern") { Task { await settings.saveKey() } }
                    .disabled(settings.isWorking || settings.editor.keyDraft.isEmpty)
            }
            HStack(spacing: 12) {
                Button("Verbindung prüfen", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await settings.checkConnection() }
                }.disabled(settings.isWorking)
                if settings.isChecking {
                    ProgressView().controlSize(.small)
                    Button("Abbrechen") { settings.cancel() }
                }
                Spacer()
                Button("Schlüssel löschen", role: .destructive) { Task { await settings.deleteKey() } }
                    .disabled(
                        settings.isWorking || settings.credentialState == .missing
                            || settings.credentialState == .unknown)
            }
            if let error = settings.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(AppTheme.accent)
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = settings.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                Text("Coding-Textmodell").font(.system(size: 15, weight: .semibold))
                Text(settings.preferences.requestyModelID ?? "Noch kein Textmodell ausgewählt")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                HStack {
                    TextField("Manuelle Modell-ID · provider/model", text: $editor.manualModelID)
                        .accessibilityLabel("Coding-Modell-ID")
                        .textFieldStyle(.roundedBorder)
                    Button("Übernehmen") { settings.selectModel(settings.editor.manualModelID) }
                }
                Text(
                    "Manuelle IDs sind ungeprüft. Eine gespeicherte Liste garantiert keine aktuelle Verfügbarkeit oder Kostenfreiheit."
                )
                .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                if let catalog = settings.catalog {
                    HStack {
                        Label(
                            settings.catalogIsCached ? "Gespeicherte Modellliste" : "Modellliste aktualisiert",
                            systemImage: "list.bullet")
                        Spacer()
                        Text(catalog.fetchedAt, style: .date)
                    }.font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                    TextField("Modelle durchsuchen", text: $editor.search).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Requesty-Modelle durchsuchen")
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(settings.visibleModels) { model in
                                Button {
                                    settings.selectModel(model.id)
                                } label: {
                                    HStack {
                                        Text(model.id).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                                        Spacer()
                                        if let limit = model.contextWindow {
                                            Text("\(limit) Kontext").font(.system(size: 10)).foregroundStyle(
                                                AppTheme.muted)
                                        }
                                        Image(
                                            systemName: settings.preferences.requestyModelID == model.id
                                                ? "checkmark.circle.fill" : "circle"
                                        )
                                        .foregroundStyle(AppTheme.accent)
                                    }.padding(10).contentShape(Rectangle())
                                }.buttonStyle(.borderless)
                                    .accessibilityLabel(model.id)
                                    .accessibilityAddTraits(
                                        settings.preferences.requestyModelID == model.id ? .isSelected : [])
                            }
                        }
                    }.frame(maxHeight: 250)
                    if settings.visibleModels.isEmpty {
                        Text("Keine passenden Modelle. Suche ändern oder eine manuelle ID verwenden.")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                    }
                } else {
                    Text(
                        "Lade die Modellliste mit „Verbindung prüfen“. Ohne Netz kannst du eine eigene Modell-ID hinterlegen."
                    )
                    .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                }
            }
            Text(
                "Der Schlüssel bleibt im macOS-Schlüsselbund und wird nie angezeigt. Nur Coding-Text wird an Requesty gesendet; keine Audioaufnahmen oder Snippet-Vorlagen. Coding formuliert ausschließlich deinen Entwickler-Prompt. Für die Kontextprüfung zuerst die Modellliste laden; ohne bekannte Limits bleibt das lokale Original bereit. Nutzung kann Kosten verursachen."
            )
            .font(.system(size: 11)).foregroundStyle(AppTheme.muted).lineSpacing(3)
        }
        .appCard()
        .task { await settings.load() }
    }

    private var credentialLabel: String {
        switch settings.credentialState {
        case .unknown: "Zugang noch nicht geprüft"
        case .missing: "Kein Schlüssel gespeichert"
        case .stored: "•••••••• · Im Schlüsselbund gespeichert"
        case .unavailable: "Zugang bitte im Schlüsselbund prüfen"
        }
    }
}
