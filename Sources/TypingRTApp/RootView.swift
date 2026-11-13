import SwiftUI
import TypingRTCore

@MainActor
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    switch model.selectedSection {
                    case .overview: overview
                    case .general: general
                    case .models:
                        localModel
                        RequestyView(settings: model.requesty)
                    case .dictionary: DictionaryView(library: model.dictionary)
                    case .snippets: SnippetView(library: model.snippets)
                    }
                }
                .padding(AppTheme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppTheme.background)
        }
        .frame(minWidth: 860, minHeight: 560)
        .foregroundStyle(AppTheme.text)
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
        .font(.system(size: AppTheme.bodySize))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Text("typingRT").font(.system(size: 19, weight: .semibold))
            }
            .padding(.top, 17)
            VStack(spacing: 6) {
                ForEach([AppSection.overview, .snippets, .dictionary, .models, .general], id: \.self) { section in
                    Button {
                        model.selectedSection = section
                    } label: {
                        Label(section.rawValue, systemImage: section.symbol)
                            .font(.system(size: 13, weight: model.selectedSection == section ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                model.selectedSection == section ? AppTheme.accent.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .foregroundStyle(model.selectedSection == section ? AppTheme.accent : AppTheme.muted)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(section.rawValue)
                    .accessibilityAddTraits(model.selectedSection == section ? .isSelected : [])
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("Lokal auf deinem Mac", systemImage: "desktopcomputer")
                    .font(.system(size: 11))
                Text(
                    "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Entwicklung")"
                )
                .font(.system(size: 10))
            }
            .foregroundStyle(AppTheme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
        .frame(width: AppTheme.sidebarWidth)
        .background(AppTheme.sidebar)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.selectedSection.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(AppTheme.muted)
                Text(
                    model.selectedSection == .overview
                        ? "Deine Stimme. Dein Workflow."
                        : model.selectedSection == .models
                            ? "Deine Modelle. Deine Kontrolle."
                            : model.selectedSection == .snippets
                                ? "Deine Texte. Auf Zuruf."
                                : model.selectedSection == .dictionary
                                    ? "Worte, die zu dir gehören." : "Dein Diktiermodus."
                )
                .font(.system(size: AppTheme.titleSize, weight: .semibold))
                .tracking(-0.7)
            }
            Spacer(minLength: 12)
            Label(
                model.dictation.isBusy ? "Diktat aktiv" : model.readiness.canStart ? "Bereit" : "Einrichtung",
                systemImage: model.dictation.isBusy
                    ? "waveform" : model.readiness.canStart ? "checkmark.circle" : "circle.dotted"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(AppTheme.raised, in: Capsule())
            .fixedSize()

        }
        .padding(.top, 8)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    Image(
                        systemName: model.dictation.isBusy
                            ? "waveform" : model.readiness.canStart ? "waveform.circle.fill" : "slider.horizontal.3"
                    )
                    .font(.system(size: 34, weight: .regular)).foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.statusTitle).font(.system(size: 21, weight: .semibold))
                        Text(
                            model.dictation.isBusy
                                ? "Ein Diktat ist aktiv. Änderungen am Modus gelten danach."
                                : model.readiness.canStart
                                    ? "Dein Text erscheint am aktiven Textcursor."
                                    : "Schließe die Einrichtung unten ab, um zu diktieren."
                        )
                        .foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Text("⌥").font(.system(size: 22, weight: .medium, design: .monospaced))
                        .frame(width: 42, height: 36).background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rechte ⌥ gedrückt halten").fontWeight(.medium)
                        Text("Sprechen. Loslassen. Weiterarbeiten.").font(.system(size: 11)).foregroundStyle(
                            AppTheme.muted)
                    }
                }.accessibilityElement(children: .combine)
            }.appCard()
            modeSelector
            MonitoringOverview(monitoring: model.monitoring)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(model.readiness.canStart ? "Alles eingerichtet" : "Einrichtung abschließen").font(
                        .system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Status prüfen", systemImage: "arrow.clockwise") { model.refreshPermissions() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                }
                VStack(spacing: 0) {
                    setupRow(
                        symbol: "mic", title: "Mikrofon", detail: microphoneDetail,
                        status: model.microphone.label, granted: model.microphone == .granted
                    ) {
                        if model.microphone != .granted {
                            Button(model.isRequestingMicrophone ? "Wird angefragt …" : "Einrichten") {
                                Task { await model.configureMicrophone() }
                            }
                            .disabled(model.isRequestingMicrophone || model.microphone == .restricted)
                        }
                    }
                    rowDivider
                    setupRow(
                        symbol: "hand.point.up.left", title: "Bedienungshilfen",
                        detail: "Zum Einfügen am aktiven Textcursor.",
                        status: model.accessibilityGranted ? "Erlaubt" : "Nicht aktiviert",
                        granted: model.accessibilityGranted
                    ) {
                        if !model.accessibilityGranted {
                            Button("Einrichten") { model.configureAccessibility() }
                        }
                    }
                    if model.selectedMode == .coding {
                        rowDivider
                        setupRow(
                            symbol: "key", title: "Coding-Zugang",
                            detail: model.requesty.canUseCoding
                                ? "Requesty und Textmodell sind hinterlegt." : model.requesty.setupMessage,
                            status: model.requesty.canUseCoding ? "Eingerichtet" : "Erforderlich",
                            granted: model.requesty.canUseCoding
                        ) {
                            Button("Zugang verwalten") { model.selectedSection = .models }
                        }
                    }
                    rowDivider
                    setupRow(
                        symbol: "cpu", title: "Lokale Spracherkennung",
                        detail: "Whisper verarbeitet deine Stimme ausschließlich auf diesem Mac.",
                        status: model.localModels.status, granted: model.readiness.modelInstalled
                    ) {
                        Button("Modell verwalten") { model.selectedSection = .models }
                    }
                }
                .padding(.horizontal, 18)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                if let message = model.systemMessage {
                    Text(message).foregroundStyle(AppTheme.muted).font(.system(size: 12))
                }
                if let message = model.dictation.message {
                    Text(message).foregroundStyle(AppTheme.muted).font(.system(size: 12))
                }
            }
            if let original = model.coding.original {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(
                            model.coding.phase == .formatting
                                ? "Englischer Prompt entsteht" : "Coding · Entscheidung erforderlich",
                            systemImage: "character.bubble"
                        )
                        .font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if model.coding.phase == .formatting { ProgressView().controlSize(.small) }
                    }
                    if let message = model.coding.message {
                        Text(message).foregroundStyle(AppTheme.accent).font(.system(size: 12))
                    }
                    if model.coding.phase == .awaitingDecision {
                        Text(original.cleanedText).textSelection(.enabled).lineSpacing(4)
                        if let rejected = model.coding.rejectedText {
                            DisclosureGroup("Abgewiesene Formulierung vergleichen · wird nicht eingefügt") {
                                Text(rejected).textSelection(.enabled).lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                        }
                        HStack {
                            Button("Erneut versuchen") { model.coding.retry(sessionID: original.sessionID) }
                            Button("Original kopieren", systemImage: "doc.on.doc") {
                                model.coding.takeOriginal(sessionID: original.sessionID)
                            }
                            Spacer()
                            Button("Verwerfen") { model.dictation.abort(message: "Diktat verworfen.") }
                                .buttonStyle(.plain).foregroundStyle(AppTheme.muted)
                        }
                    }
                    Text(
                        "Original nur flüchtig verfügbar. Wiederholen verwendet dasselbe Modell und kann erneut Kosten verursachen. Esc verwirft das Diktat."
                    )
                    .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                }.appCard()
            }
            if let result = model.delivery.result, !result.cleanedText.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(result.mode == .standard ? "Bereinigtes Diktat" : "Coding · Ergebnis")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("Verwerfen") { model.delivery.discard(sessionID: result.sessionID) }
                            .buttonStyle(.plain).foregroundStyle(AppTheme.muted)
                            .disabled(model.delivery.phase != .awaitingResult)
                        Button("Kopieren", systemImage: "doc.on.doc") {
                            model.delivery.copy(sessionID: result.sessionID)
                        }
                        .disabled(model.delivery.phase != .awaitingResult)
                    }
                    if let message = model.delivery.message {
                        Label(
                            message,
                            systemImage: model.delivery.outcome == .uncertain ? "questionmark.circle" : "info.circle"
                        )
                        .font(.system(size: 12)).foregroundStyle(AppTheme.accent)
                    }
                    if model.delivery.outcome == .uncertain {
                        Text(
                            "Ist der Text bereits angekommen, verwerfe nur diese Vorschau. Dein Textfeld bleibt unverändert."
                        )
                        .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                    }
                    Text(result.cleanedText).textSelection(.enabled).lineSpacing(4)
                    DisclosureGroup("Lokale Roherkennung") {
                        Text(result.rawText).textSelection(.enabled).lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    .font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                    Text(
                        result.mode == .standard
                            ? "Nur flüchtig gespeichert. Erst nach Kopieren oder Verwerfen ist das nächste Diktat möglich."
                            : "Nur flüchtig gespeichert. Prüfe den Text vor der Verwendung; Kopieren bestätigt keine Einfügung."
                    )
                    .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                }.appCard()
            }
        }
    }

    private var microphoneDetail: String {
        switch model.microphone {
        case .granted:
            model.dictation.isRecording
                ? "Deine Stimme wird gerade aufgenommen."
                : "Der Mikrofonzugriff ist freigegeben. Es läuft keine Aufnahme."
        case .restricted: "Der Zugriff ist vom System eingeschränkt. Prüfe die Systemeinstellungen."
        case .denied: "Erlaube den Zugriff in Datenschutz & Sicherheit → Mikrofon."
        case .notRequested: "Zum Erfassen deiner Stimme, sobald die Aufnahme verfügbar ist."
        }
    }

    private var rowDivider: some View { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

    private func setupRow<Action: View>(
        symbol: String, title: String, detail: String,
        status: String, granted: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title).fontWeight(.medium)
                    if granted { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.accent) }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(status).font(.system(size: 10)).foregroundStyle(AppTheme.muted)
                action().controlSize(.small).buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 16)
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dein Modus").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 12) {
                modeCard(.standard, symbol: "text.alignleft", description: "Originalsprache. Fülllaute entfernen.")
                modeCard(
                    .coding, symbol: "chevron.left.forwardslash.chevron.right",
                    description: "Klarer englischer Entwickler-Prompt.")
            }
            Text(
                model.dictation.isBusy
                    ? "Geänderter Modus gilt ab dem nächsten Diktat. Aktiv: \(model.dictation.activeMode.title)."
                    : "Standard bleibt lokal. Coding nutzt Requesty; Snippets sind dort deaktiviert."
            )
            .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
        }
    }

    private func modeCard(_ mode: DictationMode, symbol: String, description: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: AppTheme.motionDuration)) {
                model.selectedMode = mode
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                    Spacer()
                    Image(systemName: model.selectedMode == mode ? "checkmark.circle.fill" : "circle")
                }
                Text(mode.title).fontWeight(.semibold)
                Text(description).font(.system(size: 11)).foregroundStyle(AppTheme.muted)
            }
            .foregroundStyle(model.selectedMode == mode ? AppTheme.accent : AppTheme.text)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                model.selectedMode == mode ? AppTheme.accent.opacity(0.08) : AppTheme.surface,
                in: RoundedRectangle(cornerRadius: AppTheme.controlRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.controlRadius)
                    .strokeBorder(model.selectedMode == mode ? AppTheme.accent.opacity(0.5) : .white.opacity(0.07)))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(mode.title): \(description)")
        .accessibilityAddTraits(model.selectedMode == mode ? .isSelected : [])
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 26) {
            modeSelector
            MonitoringSettings(monitoring: model.monitoring)
            LoginItemSettings(controller: model.loginItem)
            VStack(alignment: .leading, spacing: 12) {
                Label("Deine Einstellungen bleiben auf diesem Mac.", systemImage: "lock.shield")
                    .font(.system(size: 14, weight: .medium))
                Text(
                    "Standard oder Coding wird automatisch gespeichert. Audio wird ausschließlich beim Halten der rechten Option-Taste erfasst, sobald alle Zugriffe und das lokale Modell eingerichtet sind."
                )
                .foregroundStyle(AppTheme.muted).lineSpacing(4)
                Text("Die App bleibt beim Schließen dieses Fensters in der Menüleiste erreichbar.")
                    .foregroundStyle(AppTheme.muted).lineSpacing(4)
            }
            .appCard()
        }
    }

    private var localModel: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "cpu").font(.system(size: 27)).foregroundStyle(AppTheme.accent)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Whisper Large v3 Turbo").font(.system(size: 19, weight: .semibold))
                        Text("Kompaktes Modell · etwa 630 MB Download · lokal auf Apple Silicon")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                    }
                }
                Text(
                    "Für deutsche Diktate mit englischen Fachbegriffen. Der erste Download benötigt Internet; anschließend wird dein Audio lokal verarbeitet."
                )
                .foregroundStyle(AppTheme.muted).lineSpacing(4)
                HStack {
                    Label(
                        model.localModels.status,
                        systemImage: model.localModels.installedPath == nil ? "arrow.down.circle" : "checkmark.circle"
                    )
                    .foregroundStyle(AppTheme.accent)
                    Spacer()
                    if model.localModels.isBusy {
                        if model.localModels.canCancel {
                            Button("Abbrechen") { model.localModels.cancel() }
                        }
                    } else {
                        if model.localModels.installedPath == nil {
                            Button("Modell herunterladen") {
                                Task { await model.installLocalModel() }
                            }.buttonStyle(.borderedProminent).foregroundStyle(AppTheme.background)
                        }
                        Button("Installation prüfen") { Task { await model.refreshLocalModel() } }
                    }
                }.disabled(model.dictation.isBusy)
                if model.localModels.isBusy {
                    ProgressView(value: model.localModels.progress).tint(AppTheme.accent)
                }
                if let error = model.localModels.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(AppTheme.muted).textSelection(.enabled)
                }
            }.appCard()
            VStack(alignment: .leading, spacing: 15) {
                Text("Erkennungsdienst").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 16) {
                    Text(model.workerMessage).foregroundStyle(AppTheme.muted).fixedSize(
                        horizontal: false, vertical: true)
                    Spacer()
                    Button(model.isCheckingWorker ? "Wird geprüft …" : "Dienst prüfen") {
                        Task { await model.checkWorker() }
                    }.disabled(model.isCheckingWorker || model.dictation.isBusy)
                }
                Text(
                    "Das Modell wird beim ersten Diktat im Hintergrund geladen. Beim Öffnen der App läuft keine Spracherkennung."
                )
                .font(.system(size: 11)).foregroundStyle(AppTheme.muted).lineSpacing(3)
            }.appCard()
            Label(
                "Modell-Dateien bleiben außerhalb des Projekts. Ein API-Schlüssel ist für Whisper nicht nötig.",
                systemImage: "lock.shield"
            )
            .font(.system(size: 11)).foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
