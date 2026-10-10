import Foundation

/// Debug logging, off unless `RiviumAbTestingConfig.debug` is set. Keys,
/// tokens and request bodies are never logged.
internal enum Log {
    static var isEnabled = false

    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[RiviumAbTesting] %@", message())
    }
}
