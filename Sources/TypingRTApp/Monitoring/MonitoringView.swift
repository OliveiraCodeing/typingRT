import SwiftUI
import TypingRTCore

@MainActor
struct MonitoringOverview: View {
    @Bindable var monitoring: MonitoringController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dein Fortschritt insgesamt").font(.system(size: 15, weight: .semibold))
                Spacer()
                if monitoring.isLoading || monitoring.isResetting { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .top, spacing: 12) {
                metric(title: "Typische Latenz", value: latency,
                       detail: "Median · Stopp bis fertiger Text", symbol: "timer")
                metric(title: "Gesprochene Wörter", value: monitoring.summary.map { $0.spokenWords.formatted() } ?? "—",
                       detail: "Schätzung aus der Erkennung", symbol: "waveform")
                metric(title: "Gesparte Stunden", value: monitoring.summary.map { $0.savedHours.formatted(.number.precision(.fractionLength(2))) + " h" } ?? "—",
                       detail: monitoring.summary.map { $0.savedMinutes <= 0 ? "Noch keine Zeitersparnis" : "Geschätzte Tippzeitersparnis" } ?? "Statistik wird geladen",
                       symbol: "hourglass")
            }
            Text("Nur bestätigte Einfügungen zählen zur Ersparnis. Kopieren und ungewisse Übergaben zählen nicht.")
                .font(.system(size: 11)).foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
            if let message = monitoring.message {
                Text(message).font(.system(size: 11)).foregroundStyle(AppTheme.accent)
                Button("Statistik erneut laden") { monitoring.load() }
                    .controlSize(.small).disabled(monitoring.isLoading || monitoring.isResetting)
            }
        }
    }

    private var latency: String {
        guard let value = monitoring.summary?.medianLatencySeconds else { return "—" }
        return value.formatted(.number.precision(.fractionLength(2))) + " s"
    }

    private func metric(title: String, value: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.muted)
            Text(value).font(.system(size: 30, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            Text(detail).font(.system(size: 10)).foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.06)))
    }
}

@MainActor
struct MonitoringSettings: View {
    @Bindable var monitoring: MonitoringController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Statistik & Tippgeschwindigkeit", systemImage: "timer").font(.system(size: 15, weight: .semibold))
            Text("Standard: 40 Wörter pro Minute. Deine Angabe gilt für künftig bestätigte Einfügungen; frühere Schätzungen bleiben erhalten.")
                .font(.system(size: 12)).foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField("Wörter pro Minute", text: $monitoring.wpmInput)
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                    .accessibilityLabel("Persönliche Tippgeschwindigkeit in Wörtern pro Minute")
                    .onSubmit { monitoring.saveWPM() }
                Text("Wörter / Minute").foregroundStyle(AppTheme.muted)
                Button("Speichern") { monitoring.saveWPM() }
            }
            if let error = monitoring.wpmError { Text(error).font(.system(size: 11)).foregroundStyle(AppTheme.accent) }
            if let message = monitoring.message {
                Text(message).font(.system(size: 11)).foregroundStyle(AppTheme.accent)
            }
            Text("Schätzung: Ausgabewörter ÷ Tippgeschwindigkeit minus Aufnahme-, Verarbeitungs- und unmittelbare Einfügezeit. Positive und negative Werte werden summiert. Denk- oder Programmierzeit wird nicht geschätzt.")
                .font(.system(size: 11)).foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Neuer Messbeginn").fontWeight(.medium)
                    Text("Nur Statistik löschen. Wörterbuch, Snippets und Zugang bleiben erhalten.")
                        .font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Button("Statistik zurücksetzen", role: .destructive) { monitoring.resetConfirmation = true }
                    .disabled(monitoring.isLoading || monitoring.isResetting)
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .confirmationDialog("Statistik wirklich zurücksetzen?", isPresented: $monitoring.resetConfirmation, titleVisibility: .visible) {
            Button("Statistik zurücksetzen", role: .destructive) { monitoring.reset() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle bisherigen Messwerte werden gelöscht. Laufende Diktate werden nicht in die neue Messperiode übernommen.")
        }
    }
}
