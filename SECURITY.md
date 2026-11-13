# Sicherheit

## Zugangsdaten

- typingRT liefert keinen API-Schlüssel aus und betreibt keinen eigenen Server. Für den Coding-Modus trägt jede Person ihren eigenen Requesty-Schlüssel in der App ein.
- Der Schlüssel wird ausschließlich im macOS-Schlüsselbund gespeichert. Die App liest keine `.env`-Datei und keine Umgebungsvariablen und bettet keine Schlüssel in das App-Bundle ein.
- Einstellungen, lokale Datenbanken, Exportdateien und Logs enthalten keine Schlüssel. Audio, Transkripte und Inhalte der Zwischenablage werden nicht protokolliert.

## Beiträge

Bitte keine echten Zugangsdaten, privaten Diktate oder vollständigen Anfrage-Mitschnitte in Code, Tests, Issues oder Pull Requests aufnehmen. Tests verwenden ausschließlich künstliche Werte.

Die [.gitignore](.gitignore) schließt lokale Konfiguration, Builds, Modelle, Datenbanken und Audiodateien aus. Für einen zusätzlichen Schutz vor dem Commit eignet sich [Gitleaks](https://github.com/gitleaks/gitleaks) mit der mitgelieferten [.gitleaks.toml](.gitleaks.toml):

```sh
gitleaks git --pre-commit --staged --redact --config .gitleaks.toml
```

Ist ein echter Schlüssel in ein Repository gelangt, muss er beim Anbieter gesperrt und ersetzt werden. Das Löschen aus der aktuellen Datei entfernt ihn nicht aus der Historie.

## Sicherheitsprobleme melden

Bitte Sicherheitsprobleme nicht als öffentliches Issue melden, sondern über die private Meldefunktion des Repositorys auf GitHub (Security → Report a vulnerability).
