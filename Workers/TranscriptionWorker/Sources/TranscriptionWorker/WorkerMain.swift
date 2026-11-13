import Foundation

@main
struct WorkerMain {
    static func main() {
        if CommandLine.arguments.contains("--capabilities") {
            // Does not construct WhisperKit, load models or start a microphone.
            print("WhisperKit 1.1.1")
            return
        }

        let delegate = WorkerListenerDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        withExtendedLifetime(delegate) {
            listener.resume()
        }
    }
}
