import Foundation

/// Supplies a Rivium user token for the signed-in user.
///
/// The API key ships inside the app, so it proves nothing about which user a
/// request is for. The token does: YOUR server mints it with the project's
/// server secret (POST https://auth.rivium.co/users/token), and the service
/// takes the user from it instead of trusting the userId the app sends.
///
/// Called when a token is needed, again shortly before it expires, and once
/// more if the service reports it expired. Call `completion` with the token or
/// an error, on any thread. Never put the server secret in the app.
public typealias RiviumTokenProvider = (_ completion: @escaping (Result<String, Error>) -> Void) -> Void

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

    /// Supplies a user token minted by your server; the service then takes the
    /// user from the token. Required for
    /// assigning variants, tracking events and evaluating flags. See `RiviumTokenProvider`.
    public let tokenProvider: RiviumTokenProvider?

    /// A user token you already hold. `tokenProvider` is preferred: a static
    /// token expires.
    public let userToken: String?

    /// Internal API URL
    internal static let apiUrl = "https://abtest.rivium.co"

    /// SDK version (updated by publish script)
    internal static let sdkVersion = "0.2.1"

    public init(
        apiKey: String,
        debug: Bool = false,
        flushInterval: TimeInterval = 30.0,
        maxQueueSize: Int = 100,
        autoTrack: Bool = true,
        tokenProvider: RiviumTokenProvider? = nil,
        userToken: String? = nil
    ) {
        self.apiKey = apiKey
        self.debug = debug
        self.flushInterval = flushInterval
        self.maxQueueSize = maxQueueSize
        self.autoTrack = autoTrack
        self.tokenProvider = tokenProvider
        self.userToken = userToken
    }

    /// Create config from API key only
    public static func fromApiKey(_ apiKey: String) -> RiviumAbTestingConfig {
        return RiviumAbTestingConfig(apiKey: apiKey)
    }
}
