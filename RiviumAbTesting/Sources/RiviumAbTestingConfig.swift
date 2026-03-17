import Foundation

/// Configuration for RiviumAbTesting SDK
public struct RiviumAbTestingConfig {
    /// API key for authentication (format: rv_live_xxx or rv_test_xxx)
    public let apiKey: String

    /// Enable debug logging
    public let debug: Bool

    /// Interval for flushing events (in seconds)
    public let flushInterval: TimeInterval

    /// Maximum events to queue before forcing flush
    public let maxQueueSize: Int

    /// Enable automatic tracking
    public let autoTrack: Bool

    /// Internal API URL
    internal static let apiUrl = "https://abtest.rivium.co"

    /// SDK version (updated by publish script)
    internal static let sdkVersion = "1.0.0"

    public init(
        apiKey: String,
        debug: Bool = false,
        flushInterval: TimeInterval = 30.0,
        maxQueueSize: Int = 100,
        autoTrack: Bool = true
    ) {
        self.apiKey = apiKey
        self.debug = debug
        self.flushInterval = flushInterval
        self.maxQueueSize = maxQueueSize
        self.autoTrack = autoTrack
    }

    /// Create config from API key only
    public static func fromApiKey(_ apiKey: String) -> RiviumAbTestingConfig {
        return RiviumAbTestingConfig(apiKey: apiKey)
    }
}
