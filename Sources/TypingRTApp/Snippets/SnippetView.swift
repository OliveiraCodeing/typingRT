import AppKit
import SwiftUI
import TypingRTCore
import UniformTypeIdentifiers

@MainActor
struct SnippetView: View {
    @Bindable var library: SnippetLibrary
    @Bindable private var editor: SnippetEditor
    init(library: SnippetLibrary) {
        self.library = library
        editor = library.editor
    }
    private var entries: [SnippetEntry] { library.snapshot.entries.filter { $0.matches(search: editor.search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Ein kurzer Aufruf. Dein ganzer Text.").font(.system(size: 19, weight: .semibold))
                    Label("Nur im Standard-Modus aktiv", systemImage: "text.alignleft").foregroundStyle(AppTheme.accent)
                    Text("Sage „Snippet“ und deinen Auslöser. Änderungen gelten ab dem nächsten Diktat.")
                        .foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Neues Snippet", systemImage: "plus") {
                    library.clearMessages()
                    editor.edit(nil)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(AppTheme.background).disabled(
                    !library.isLoaded || library.isWorking)
            }
            HStack {
                TextField("Name oder Auslöser suchen", text: $editor.search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Snippets durchsuchen")
                Button("Importieren", systemImage: "square.and.arrow.down") { chooseImport() }
                Button("Exportieren", systemImage: "square.and.arrow.up") { chooseExport() }
            }.disabled(!library.isLoaded || library.isWorking)
            if let message = library.errorMessage {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle")
                    if !library.isLoaded { Button("Erneut laden") { Task { await library.load() } } }
                }.foregroundStyle(AppTheme.accent).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = library.notice {
                Label(notice, systemImage: "checkmark.circle").foregroundStyle(AppTheme.muted)
            }
            if !library.isLoaded && library.isWorking {
                ProgressView("Snippets werden geladen …").frame(maxWidth: .infinity).padding(36)
            } else if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus").font(.system(size: 34)).foregroundStyle(AppTheme.accent)
                    Text(editor.search.isEmpty ? "Deine Texte auf Zuruf" : "Keine passenden Snippets").font(
                        .system(size: 16, weight: .semibold))
                    Text(
                        editor.search.isEmpty
                            ? "Signaturen, Antworten und wiederkehrende Texte. Lokal auf deinem Mac."
                            : "Versuche einen anderen Namen oder Auslöser."
                    )
                    .foregroundStyle(AppTheme.muted)
                    if editor.search.isEmpty {
                        Button("Erstes Snippet hinzufügen") {
                            library.clearMessages()
                            editor.edit(nil)
                        }.disabled(!library.isLoaded)
                    }
                }.multilineTextAlignment(.center).padding(.horizontal, 24).frame(maxWidth: .infinity).padding(
                    .vertical, 44
                ).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            } else {
                Text("\(entries.count) Snippets · nur auf diesem Mac").font(.system(size: 11)).foregroundStyle(
                    AppTheme.muted)
                LazyVStack(spacing: 10) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "text.quote").foregroundStyle(AppTheme.accent).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(entry.name).font(.system(size: 14, weight: .semibold))
                                    Text("Snippet \(entry.trigger)").font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(AppTheme.accent)
                                    Text(entry.template).font(.system(size: 12)).foregroundStyle(AppTheme.muted)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            HStack {
                                Spacer()
                                Button("Vorschau") { editor.preview = entry }
                                Button("Bearbeiten") {
                                    library.clearMessages()
                                    editor.edit(entry)
                                }
                                Button {
                                    editor.pendingDeletion = entry
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("\(entry.name) löschen")
                            }
                        }.padding(16).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12)).disabled(
                            library.isWorking)
                    }
                }
            }
            Text("JSON-Sicherungen enthalten deine Vorlagen. Wähle zum Export einen privaten Speicherort.")
                .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
        }
        .sheet(isPresented: $editor.showingEditor) { editSheet }
        .sheet(item: $editor.preview) { entry in
            VStack(alignment: .leading, spacing: 18) {
                Text(entry.name).font(.system(size: 23, weight: .semibold))
                Label("Snippet \(entry.trigger)", systemImage: "waveform").foregroundStyle(AppTheme.accent)
                ScrollView {
                    Text(entry.template).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180, maxHeight: 320).padding(16).background(
                    AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Spacer()
                    Button("Schließen") { editor.preview = nil }.keyboardShortcut(.cancelAction)
                }
            }.padding(28).frame(width: 540).background(AppTheme.background).foregroundStyle(AppTheme.text)
                .preferredColorScheme(.dark)
        }
        .confirmationDialog(
            "Snippet löschen?",
            isPresented: Binding(
                get: { editor.pendingDeletion != nil }, set: { if !$0 { editor.pendingDeletion = nil } })
        ) {
            Button("Löschen", role: .destructive) {
                guard let entry = editor.pendingDeletion else { return }
                Task {
                    _ = await library.delete(id: entry.id)
                    editor.pendingDeletion = nil
                }
            }
        } message: {
            Text("Die ausgewählte Vorlage wird von diesem Mac entfernt.")
        }
    }
    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.editingID == nil ? "Neues Snippet" : "Snippet bearbeiten").font(
                .system(size: 23, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name", key: "name") {
                        TextField("Zum Beispiel E-Mail-Signatur", text: $editor.name).textFieldStyle(.roundedBorder)
                    }
                    field("Gesprochener Auslöser", key: "trigger") {
                        TextField("Zum Beispiel Signatur", text: $editor.trigger).textFieldStyle(.roundedBorder)
                    }
                    field("Aussprachevarianten · optional, eine pro Zeile", key: "aliases") {
                        TextEditor(text: $editor.aliases).frame(height: 52).font(.system(size: 13))
                    }
                    field("Vorlagentext · wird unverändert eingesetzt", key: "template") {
                        TextEditor(text: $editor.template).frame(height: 155).font(
                            .system(size: 13, design: .monospaced))
                    }
                    if let error = library.errorMessage,
                        !["name", "trigger", "aliases", "template"].contains(library.fieldError ?? "")
                    {
                        Text(error).foregroundStyle(AppTheme.accent).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }.frame(maxHeight: 370)
            HStack {
                Spacer()
                Button("Abbrechen") { editor.showingEditor = false }.keyboardShortcut(.cancelAction)
                Button(library.isWorking ? "Speichert …" : "Speichern") {
                    let aliases =
                        editor.aliases.isEmpty
                        ? [] : editor.aliases.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                    Task {
                        if await library.save(
                            id: editor.editingID, name: editor.name, trigger: editor.trigger, aliases: aliases,
                            template: editor.template)
                        {
                            editor.showingEditor = false
                        }
                    }
                }.buttonStyle(.borderedProminent).foregroundStyle(AppTheme.background)
            }.disabled(library.isWorking)
        }.padding(28).frame(width: 540).background(AppTheme.background).foregroundStyle(AppTheme.text).tint(
            AppTheme.accent
        )
        .preferredColorScheme(.dark).interactiveDismissDisabled(library.isWorking)
    }
    private func field<Content: View>(_ label: String, key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium))
            content().accessibilityLabel(label)
            if library.fieldError == key, let error = library.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(AppTheme.accent)
            }
        }
    }
    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await library.importFile(url) }
        }
    }
    private func chooseExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "typingRT-snippets.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await library.exportFile(url) }
        }
    }
}
