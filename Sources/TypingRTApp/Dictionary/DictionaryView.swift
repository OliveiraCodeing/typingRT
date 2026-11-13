import SwiftUI
import TypingRTCore

@MainActor @Observable
final class DictionaryEditor {
    var search = ""
    var editingID: UUID?
    var canonical = ""
    var aliases = ""
    var isProtected = false
    var showingEditor = false
    var pendingDeletion: DictionaryEntry?

    func edit(_ entry: DictionaryEntry?) {
        editingID = entry?.id
        canonical = entry?.canonical ?? ""
        aliases = entry?.aliases.joined(separator: "\n") ?? ""
        isProtected = entry?.isProtected ?? false
        showingEditor = true
    }
}

@MainActor
struct DictionaryView: View {
    @Bindable var library: DictionaryLibrary
    @Bindable private var editor: DictionaryEditor

    init(library: DictionaryLibrary) {
        self.library = library
        self.editor = library.editor
    }

    private var entries: [DictionaryEntry] {
        let query = editor.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.snapshot.entries.filter { entry in
            query.isEmpty || ([entry.canonical] + entry.aliases).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Deine Begriffe. Richtig geschrieben.").font(.system(size: 19, weight: .semibold))
                    Text("Namen und Fachbegriffe für Standard und Coding. Änderungen gelten ab dem nächsten Diktat.")
                        .foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Neuer Begriff", systemImage: "plus") { editor.edit(nil) }
                    .buttonStyle(.borderedProminent).foregroundStyle(AppTheme.background).disabled(
                        !library.isLoaded || library.isWorking)
            }
            if let error = library.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    if !library.isLoaded { Button("Erneut laden") { Task { await library.load() } } }
                }
                .foregroundStyle(AppTheme.accent).padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 10))
            }
            TextField("Begriffe und Aussprachevarianten suchen", text: $editor.search)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Wörterbuch durchsuchen")
            if !library.isLoaded && library.isWorking {
                ProgressView("Wörterbuch wird geladen …").frame(maxWidth: .infinity).padding(32)
            } else if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "character.book.closed").font(.system(size: 34)).foregroundStyle(AppTheme.accent)
                    Text(editor.search.isEmpty ? "Platz für deine Fachbegriffe" : "Keine passenden Begriffe")
                        .font(.system(size: 16, weight: .semibold))
                    Text(
                        editor.search.isEmpty
                            ? "Zum Beispiel: Supabase mit der Aussprachevariante Supa Base."
                            : "Versuche eine andere Schreibweise."
                    )
                    .foregroundStyle(AppTheme.muted)
                    if editor.search.isEmpty {
                        Button("Ersten Begriff hinzufügen") { editor.edit(nil) }.disabled(!library.isLoaded)
                    }
                }.multilineTextAlignment(.center).padding(.horizontal, 24).frame(maxWidth: .infinity).padding(
                    .vertical, 44
                )
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            } else {
                HStack {
                    Text("\(entries.count) Begriffe").foregroundStyle(AppTheme.muted)
                    Spacer()
                    Text("Nur auf diesem Mac").foregroundStyle(AppTheme.muted)
                }.font(.system(size: 11))
                LazyVStack(spacing: 8) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: entry.isProtected ? "lock.shield" : "textformat.abc")
                                    .foregroundStyle(AppTheme.accent).frame(width: 24)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.canonical).font(.system(size: 14, weight: .semibold))
                                    Text(
                                        entry.aliases.isEmpty
                                            ? "Kanonische Schreibweise" : entry.aliases.joined(separator: " · ")
                                    )
                                    .font(.system(size: 12)).foregroundStyle(AppTheme.muted).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            HStack {
                                Spacer()
                                Button("Bearbeiten") { editor.edit(entry) }
                                Button {
                                    editor.pendingDeletion = entry
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("\(entry.canonical) löschen")
                            }
                        }.padding(16).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .disabled(library.isWorking)
                    }
                }
            }
            Label(
                "Erkennungskontext hilft Whisper. Eindeutige Varianten werden anschließend lokal ersetzt.",
                systemImage: "info.circle"
            )
            .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $editor.showingEditor) { editSheet }
        .confirmationDialog(
            "Begriff löschen?",
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
            Text("Der Begriff und seine Varianten werden aus dem Wörterbuch entfernt.")
        }
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editor.editingID == nil ? "Neuer Begriff" : "Begriff bearbeiten").font(
                .system(size: 23, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Gewünschte Schreibweise").fontWeight(.medium)
                        TextField("Zum Beispiel Supabase", text: $editor.canonical).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Gewünschte Schreibweise")
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Aussprache- und Fehltranskriptionsvarianten").fontWeight(.medium)
                        Text("Eine Variante pro Zeile. Optional.").font(.system(size: 11)).foregroundStyle(
                            AppTheme.muted)
                        TextEditor(text: $editor.aliases).accessibilityLabel("Aussprachevarianten, eine pro Zeile")
                            .font(.system(size: 13)).frame(height: 104)
                            .padding(5).background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Toggle("Als Bezeichner schützen", isOn: $editor.isProtected)
                    Text("Im Coding-Modus muss dieser Name im englischen Ergebnis exakt erhalten bleiben.")
                        .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                    if let error = library.errorMessage {
                        Text(error).foregroundStyle(AppTheme.accent).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }.frame(maxHeight: 350)
            HStack {
                Spacer()
                Button("Abbrechen") { editor.showingEditor = false }.keyboardShortcut(.cancelAction)
                Button(library.isWorking ? "Speichert …" : "Speichern") {
                    let variants =
                        editor.aliases.isEmpty
                        ? [] : editor.aliases.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                    Task {
                        if await library.save(
                            id: editor.editingID, canonical: editor.canonical, aliases: variants,
                            isProtected: editor.isProtected)
                        {
                            editor.showingEditor = false
                        }
                    }
                }.buttonStyle(.borderedProminent).foregroundStyle(AppTheme.background).keyboardShortcut(.defaultAction)
            }.disabled(library.isWorking)
        }.padding(28).frame(width: 520).background(AppTheme.background)
            .foregroundStyle(AppTheme.text).tint(AppTheme.accent).preferredColorScheme(.dark)
            .interactiveDismissDisabled(library.isWorking)
    }
}
