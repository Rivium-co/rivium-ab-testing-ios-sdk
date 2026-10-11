import Foundation

/// Why a call to the service gave no result.
internal struct ApiFailure: Error {
    /// HTTP status, or nil when there was no answer (no network).
    let status: Int?
    /// The service's own error code (`token_required`, `token_expired`, ...).
    let code: String?
    let message: String
    /// How long the service asked us to wait (HTTP 429), in seconds.
    let retryAfter: TimeInterval?

    init(status: Int?, code: String? = nil, message: String, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }

    /// The error as the app sees it.
    var publicError: RiviumAbTestingError {
        if let status = status { return .apiError(status, message) }
        return .networkError(message)
    }
}

/// HTTP calls to the service.
///
/// Reads (experiments, flags, config) need only the API key. Calls that act
/// for a user (assign, events, flag evaluation) take the user token to send.
internal class ApiClient {
    /// The most events the service takes in one request.
    static let maxEventsPerRequest = 100

    private let config: RiviumAbTestingConfig
    private let session: URLSession

    init(config: RiviumAbTestingConfig, sessionConfiguration: URLSessionConfiguration = .default) {
        self.config = config

        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    private var baseUrl: String {
        return RiviumAbTestingConfig.apiUrl
    }

    // MARK: - Requests

    /// One request: the API key, the user token when given, and the answer
    /// or why there is none.
    private func perform(
        _ path: String,
        body: Data? = nil,
        token: String? = nil,
        completion: @escaping (Result<Data, ApiFailure>) -> Void
    ) {
        guard let url = URL(string: "\(baseUrl)\(path)") else {
            completion(.failure(ApiFailure(status: nil, message: "Invalid API URL")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        if let token = token {
            request.setValue(token, forHTTPHeaderField: "x-user-token")
        }
        let route = path.components(separatedBy: "?")[0]
        Log.debug("→ \(request.httpMethod ?? "") \(route)")

        session.dataTask(with: request) { data, response, error in
            guard let http = response as? HTTPURLResponse else {
                Log.debug("← no answer \(route)")
                completion(.failure(ApiFailure(status: nil, message: error?.localizedDescription ?? "Invalid response")))
                return
            }
            Log.debug("← \(http.statusCode) \(route)")
            // Any 2xx is a success: the service answers 200 or 201 for the same call.
            if (200..<300).contains(http.statusCode) {
                completion(.success(data ?? Data()))
                return
            }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            completion(.failure(ApiFailure(
                status: http.statusCode,
                code: json?["code"] as? String,
                message: (json?["message"] as? String) ?? "Request failed",
                retryAfter: retryAfter
            )))
        }.resume()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ result: Result<Data, ApiFailure>) -> Result<T, ApiFailure> {
        switch result {
        case .failure(let failure):
            return .failure(failure)
        case .success(let data):
            do {
                return .success(try JSONDecoder().decode(type, from: data))
            } catch {
                return .failure(ApiFailure(status: nil, message: "Failed to decode response: \(error.localizedDescription)"))
            }
        }
    }

    private func json(_ payload: [String: Any]) -> Data {
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    // MARK: - Init SDK

    /// Initialize SDK and get experiments + config in one call
    func initSdk(platform: String = "ios", completion: @escaping (Result<InitResponse, ApiFailure>) -> Void) {
        perform("/public/init?platform=\(platform)&sdkVersion=\(RiviumAbTestingConfig.sdkVersion)") { result in
            completion(self.decode(InitResponse.self, result))
        }
    }

    // MARK: - Experiments

    /// Fetch all running experiments for the project (uses initSdk internally)
    func fetchExperiments(completion: @escaping (Result<[Experiment], ApiFailure>) -> Void) {
        initSdk { result in
            completion(result.map { $0.experiments })
        }
    }

    // MARK: - Feature Flags

    /// Fetch all feature flags for the project
    func fetchFeatureFlags(completion: @escaping (Result<[FeatureFlag], ApiFailure>) -> Void) {
        perform("/public/flags") { result in
            completion(self.decode(FlagsResponse.self, result).map { $0.flags ?? [] })
        }
    }

    /// Evaluate a feature flag for a user
    func evaluateFlag(
        flagKey: String,
        userId: String,
        userAttributes: [String: Any]?,
        token: String,
        completion: @escaping (Result<FlagEvaluationResult, ApiFailure>) -> Void
    ) {
        let payload: [String: Any] = [
            "flagKey": flagKey,
            "userId": userId,
            "userAttributes": userAttributes ?? [:]
        ]
        perform("/public/flag-evaluation", body: json(payload), token: token) { result in
            completion(self.decode(FlagEvaluationResult.self, result))
        }
    }

    // MARK: - Assignment

    /// Get or create assignment for a user in an experiment
    func getAssignment(
        experimentKey: String,
        userId: String,
        userAttributes: [String: Any]?,
        token: String,
        completion: @escaping (Result<Assignment, ApiFailure>) -> Void
    ) {
        let payload: [String: Any] = [
            "experimentKey": experimentKey,
            "userId": userId,
            "userAttributes": userAttributes ?? [:]
        ]
        perform("/public/assign", body: json(payload), token: token) { result in
            switch self.decode(ApiResponse<Assignment>.self, result) {
            case .success(let response):
                if let assignment = response.data {
                    completion(.success(assignment))
                } else {
                    completion(.failure(ApiFailure(status: nil, message: "Experiment not found: \(experimentKey)")))
                }
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    // MARK: - Events

    /// Track events (at most `maxEventsPerRequest` per call)
    func trackEvents(
        _ events: [TrackEvent],
        token: String,
        completion: @escaping (Result<Void, ApiFailure>) -> Void
    ) {
        guard let body = try? JSONEncoder().encode(["events": events]) else {
            // Would fail the same way every time: nothing to retry.
            completion(.failure(ApiFailure(status: 400, message: "Failed to encode request")))
            return
        }
        perform("/public/track/batch", body: body, token: token) { result in
            completion(result.map { _ in () })
        }
    }
}

// MARK: - Response Types

private struct ApiResponse<T: Decodable>: Decodable {
    let data: T?
    let error: String?
}

struct InitResponse: Decodable {
    let experiments: [Experiment]
    let config: SdkConfig?
    let serverTime: String?

    private enum CodingKeys: String, CodingKey {
        case experiments, config, serverTime
    }

    init(experiments: [Experiment] = [], config: SdkConfig? = nil, serverTime: String? = nil) {
        self.experiments = experiments
        self.config = config
        self.serverTime = serverTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        experiments = (try? container.decodeIfPresent([Experiment].self, forKey: .experiments)) ?? []
        config = try? container.decodeIfPresent(SdkConfig.self, forKey: .config)
        serverTime = try? container.decodeIfPresent(String.self, forKey: .serverTime)
    }
}

/// What the console says. A value that is missing is nil: the SDK keeps what it uses.
struct SdkConfig: Decodable {
    let cacheTtlSeconds: Int?
    let syncIntervalSeconds: Int?
    let maxOfflineEvents: Int
    let maxBatchSize: Int
    let enableOfflineMode: Bool
    let enableDebugMode: Bool

    private enum CodingKeys: String, CodingKey {
        case cacheTtlSeconds, syncIntervalSeconds, maxOfflineEvents, maxBatchSize, enableOfflineMode, enableDebugMode
    }

    init(
        cacheTtlSeconds: Int? = nil,
        syncIntervalSeconds: Int? = nil,
        maxOfflineEvents: Int = 1000,
        maxBatchSize: Int = 100,
        enableOfflineMode: Bool = true,
        enableDebugMode: Bool = false
    ) {
        self.cacheTtlSeconds = cacheTtlSeconds
        self.syncIntervalSeconds = syncIntervalSeconds
        self.maxOfflineEvents = maxOfflineEvents
        self.maxBatchSize = maxBatchSize
        self.enableOfflineMode = enableOfflineMode
        self.enableDebugMode = enableDebugMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheTtlSeconds = (try? container.decodeIfPresent(Int.self, forKey: .cacheTtlSeconds)) ?? nil
        syncIntervalSeconds = (try? container.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds)) ?? nil
        maxOfflineEvents = (try? container.decodeIfPresent(Int.self, forKey: .maxOfflineEvents)) ?? 1000
        maxBatchSize = (try? container.decodeIfPresent(Int.self, forKey: .maxBatchSize)) ?? 100
        enableOfflineMode = (try? container.decodeIfPresent(Bool.self, forKey: .enableOfflineMode)) ?? true
        enableDebugMode = (try? container.decodeIfPresent(Bool.self, forKey: .enableDebugMode)) ?? false
    }
}

private struct FlagsResponse: Decodable {
    let flags: [FeatureFlag]?
}
