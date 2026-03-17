import Foundation

/// RiviumAbTesting SDK errors
public enum RiviumAbTestingError: Error, LocalizedError {
    case notInitialized
    case invalidConfig(String)
    case networkError(String)
    case experimentNotFound(String)
    case apiError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "RiviumAbTesting SDK not initialized"
        case .invalidConfig(let message):
            return "Invalid configuration: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .experimentNotFound(let key):
            return "Experiment not found: \(key)"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        }
    }
}
