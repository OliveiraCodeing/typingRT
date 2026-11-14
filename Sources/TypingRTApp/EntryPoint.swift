import AppKit
import Darwin
import TypingRTCore

@main
struct EntryPoint {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--worker-check") {
            switch WorkerClient.bundleState {
            case .bundled: break
            case .notBundled:
                FileHandle.standardError.write(Data("Kein gebündelter WhisperKit-Worker vorhanden.\n".utf8))
                Darwin.exit(3)
            case .appMoved:
                FileHandle.standardError.write(Data("App-Bundle wurde seit dem Start verschoben; bitte neu starten.\n".utf8))
                Darwin.exit(5)
            }
            Task { @MainActor in
                do {
                    let capability = try await WorkerClient().inspect()
                    let data = try JSONEncoder().encode(capability)
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                    Darwin.exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Worker-Prüfung fehlgeschlagen.\n".utf8))
                    Darwin.exit(4)
                }
            }
            RunLoop.main.run()
            Darwin.exit(4)
        }
        if CommandLine.arguments.contains("--smoke-test") {
            guard let index = CommandLine.arguments.firstIndex(of: "--report"),
                  index + 1 < CommandLine.arguments.count,
                  !CommandLine.arguments[index + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("--smoke-test benötigt --report <Datei>.\n".utf8))
                Darwin.exit(2)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
