import Foundation

internal class ApiClient {
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

    // MARK: - Requests and the user token

    /// Fetch a new token this many seconds before the current one expires.
    private static let tokenRefreshSkew: TimeInterval = 60

    private let tokenLock = NSLock()
    private var cachedToken: String?
    private var cachedTokenExpiresAt: TimeInterval = 0
    private var tokenWaiters: [(String?) -> Void] = []

    /// True when requests carry a user token (the service then credits them to its user).
    var usesUserToken: Bool {
        return config.tokenProvider != nil || config.userToken != nil
    }

    /// Forget the cached token, e.g. when another user signs in.
    func clearToken() {
        tokenLock.lock()
        cachedToken = nil
        cachedTokenExpiresAt = 0
        tokenLock.unlock()
    }

    /// The token held right now, without fetching a new one.
    func peekToken() -> String? {
        if let token = config.userToken { return token }
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return cachedToken
    }

    /// The current token, fetched through the provider when needed. Concurrent
    /// callers share one provider call.
    private func withToken(_ completion: @escaping (String?) -> Void) {
        if let token = config.userToken { return completion(token) }
        guard let provider = config.tokenProvider else { return completion(nil) }

        tokenLock.lock()
        if let token = cachedToken,
           cachedTokenExpiresAt - Self.tokenRefreshSkew > Date().timeIntervalSince1970 {
            tokenLock.unlock()
            return completion(token)
        }
        tokenWaiters.append(completion)
        let first = tokenWaiters.count == 1
        tokenLock.unlock()
        guard first else { return }

        provider { [weak self] result in
            guard let self = self else { return }
            self.tokenLock.lock()
            if case .success(let token) = result {
                self.cachedToken = token
                self.cachedTokenExpiresAt = Self.tokenExpiry(token)
            }
            let token = self.cachedToken
            let waiters = self.tokenWaiters
            self.tokenWaiters = []
            self.tokenLock.unlock()
            waiters.forEach { $0(token) }
        }
    }

    /// Every call to the service goes through here: the API key, the user
    /// token and one retry with a fresh token when the service says it expired.
    ///
    /// `explicitToken` sends a specific token instead (a user who just signed
    /// out still has events to send under their own token).
    private func perform(
        _ request: URLRequest,
        explicitToken: String?? = nil,
        retry: Bool = true,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        let original = request
        let send: (String?) -> Void = { [weak self] token in
            guard let self = self else { return }
            var request = original
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(self.config.apiKey, forHTTPHeaderField: "x-api-key")
            if let token = token {
                request.setValue(token, forHTTPHeaderField: "x-user-token")
            }
            self.session.dataTask(with: request) { data, response, error in
                if retry, explicitToken == nil, self.config.tokenProvider != nil,
                   (response as? HTTPURLResponse)?.statusCode == 401,
                   Self.errorCode(data) == "token_expired" {
                    self.clearToken()
                    self.perform(original, retry: false, completion: completion)
                    return
                }
                completion(data, response, error)
            }.resume()
        }

        if let explicit = explicitToken {
            send(explicit)
        } else {
            withToken(send)
        }
    }

    /// `exp` from the token payload; 0 (fetch again next time) if unreadable.
    private static func tokenExpiry(_ token: String) -> TimeInterval {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return 0 }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? NSNumber else { return 0 }
        return exp.doubleValue
    }

    private static func errorCode(_ data: Data?) -> String? {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["code"] as? String
    }

    // MARK: - Init SDK

    /// Initialize SDK and get experiments + config in one call
    func initSdk(platform: String = "ios", completion: @escaping (Result<InitResponse, RiviumAbTestingError>) -> Void) {
        guard let url = URL(string: "\(baseUrl)/public/init?platform=\(platform)&sdkVersion=\(RiviumAbTestingConfig.sdkVersion)") else {
            completion(.failure(.invalidConfig("Invalid API URL")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        perform(request) { data, response, error in
            if let error = error {
                completion(.failure(.networkError(error.localizedDescription)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.networkError("Invalid response")))
                return
            }

            guard httpResponse.statusCode == 200, let data = data else {
                completion(.failure(.apiError(httpResponse.statusCode, "Request failed")))
                return
            }

            do {
                let initResponse = try JSONDecoder().decode(InitResponse.self, from: data)
                completion(.success(initResponse))
            } catch {
                completion(.failure(.networkError("Failed to decode response: \(error.localizedDescription)")))
            }
        }
    }

    // MARK: - Experiments

    /// Fetch all running experiments for the project (uses initSdk internally)
    func fetchExperiments(completion: @escaping (Result<[Experiment], RiviumAbTestingError>) -> Void) {
        initSdk { result in
            switch result {
            case .success(let initResponse):
                completion(.success(initResponse.experiments))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Feature Flags

    /// Fetch all feature flags for the project
    func fetchFeatureFlags(completion: @escaping (Result<[FeatureFlag], RiviumAbTestingError>) -> Void) {
        guard let url = URL(string: "\(baseUrl)/public/flags") else {
            completion(.failure(.invalidConfig("Invalid API URL")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        perform(request) { data, response, error in
            if let error = error {
                completion(.failure(.networkError(error.localizedDescription)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.networkError("Invalid response")))
                return
            }

            guard httpResponse.statusCode == 200, let data = data else {
                completion(.failure(.apiError(httpResponse.statusCode, "Request failed")))
                return
            }

            do {
                let flagsResponse = try JSONDecoder().decode(FlagsResponse.self, from: data)
                completion(.success(flagsResponse.flags ?? []))
            } catch {
                completion(.failure(.networkError("Failed to decode response: \(error.localizedDescription)")))
            }
        }
    }

    /// Evaluate a feature flag for a user
    func evaluateFlag(
        flagKey: String,
        userId: String,
        userAttributes: [String: Any]?,
        completion: @escaping (Result<FlagEvaluationResult, RiviumAbTestingError>) -> Void
    ) {
        guard let url = URL(string: "\(baseUrl)/public/flag-evaluation") else {
            completion(.failure(.invalidConfig("Invalid API URL")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let payload: [String: Any] = [
            "flagKey": flagKey,
            "userId": userId,
            "userAttributes": userAttributes ?? [:]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(.networkError("Failed to encode request")))
            return
        }

        perform(request) { data, response, error in
            if let error = error {
                completion(.failure(.networkError(error.localizedDescription)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.networkError("Invalid response")))
                return
            }

            guard httpResponse.statusCode == 200, let data = data else {
                completion(.failure(.apiError(httpResponse.statusCode, "Request failed")))
                return
            }

            do {
                let result = try JSONDecoder().decode(FlagEvaluationResult.self, from: data)
                completion(.success(result))
            } catch {
                completion(.failure(.networkError("Failed to decode response: \(error.localizedDescription)")))
            }
        }
    }

    // MARK: - Assignment

    /// Get or create assignment for a user in an experiment
    func getAssignment(
        experimentKey: String,
        userId: String,
        userAttributes: [String: Any]?,
        completion: @escaping (Result<Assignment, RiviumAbTestingError>) -> Void
    ) {
        guard let url = URL(string: "\(baseUrl)/public/assign") else {
            completion(.failure(.invalidConfig("Invalid API URL")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let payload: [String: Any] = [
            "experimentKey": experimentKey,
            "userId": userId,
            "userAttributes": userAttributes ?? [:]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(.networkError("Failed to encode request")))
            return
        }

        perform(request) { data, response, error in
            if let error = error {
                completion(.failure(.networkError(error.localizedDescription)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.networkError("Invalid response")))
                return
            }

            guard httpResponse.statusCode == 200, let data = data else {
                completion(.failure(.apiError(httpResponse.statusCode, "Request failed")))
                return
            }

            do {
                let apiResponse = try JSONDecoder().decode(ApiResponse<Assignment>.self, from: data)
                if let assignment = apiResponse.data {
                    completion(.success(assignment))
                } else {
                    completion(.failure(.experimentNotFound(experimentKey)))
                }
            } catch {
                completion(.failure(.networkError("Failed to decode response: \(error.localizedDescription)")))
            }
        }
    }

    // MARK: - Events

    /// Track events
    func trackEvents(
        _ events: [TrackEvent],
        explicitToken: String?? = nil,
        completion: @escaping (Result<Void, RiviumAbTestingError>) -> Void
    ) {
        guard let url = URL(string: "\(baseUrl)/public/track/batch") else {
            completion(.failure(.invalidConfig("Invalid API URL")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        do {
            let payload = ["events": events]
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(.networkError("Failed to encode request")))
            return
        }

        perform(request, explicitToken: explicitToken) { _, response, error in
            if let error = error {
                completion(.failure(.networkError(error.localizedDescription)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(.failure(.apiError(code, "Request failed")))
                return
            }

            completion(.success(()))
        }
    }

    // MARK: - Offline Sync

    /// Sync offline events with server
    func syncOfflineEvents(
        events: [TrackEvent],
        deviceId: String,
        completion: @escaping (Result<SyncResult, RiviumAbTestingError>) -> Void
    ) {
        guard let url = URL(string: "\(baseUrl)/public/sync") else {
            completion(.failure(.invalidConfig("Invalid API URL")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let eventDicts: [[String: Any]] = events.map { event in
            var dict: [String: Any] = [
                "experimentId": event.experimentId,
                "variantId": event.variantId,
                "userId": event.userId,
                "eventType": event.eventType.rawValue,
                "eventName": event.eventName ?? event.eventType.rawValue,
                "timestamp": event.timestamp
            ]
            if let value = event.eventValue {
                dict["eventValue"] = value
            }
            if let props = event.properties {
                dict["metadata"] = props
            }
            return dict
        }

        let payload: [String: Any] = [
            "events": eventDicts,
            "deviceId": deviceId,
            "sdkVersion": "ios-\(RiviumAbTestingConfig.sdkVersion)"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(.networkError("Failed to encode request")))
            return
        }

        perform(request) { data, response, error in
            if let error = error {
                completion(.failure(.networkError(error.localizedDescription)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.networkError("Invalid response")))
                return
            }

            guard httpResponse.statusCode == 200, let data = data else {
                completion(.failure(.apiError(httpResponse.statusCode, "Request failed")))
                return
            }

            do {
                let syncResponse = try JSONDecoder().decode(SyncResponse.self, from: data)
                completion(.success(SyncResult(
                    synced: syncResponse.synced,
                    failed: syncResponse.failed,
                    errors: syncResponse.errors
                )))
            } catch {
                completion(.failure(.networkError("Failed to decode response: \(error.localizedDescription)")))
            }
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

struct SdkConfig: Decodable {
    let cacheTtlSeconds: Int
    let syncIntervalSeconds: Int
    let maxOfflineEvents: Int
    let maxBatchSize: Int
    let enableOfflineMode: Bool
    let enableDebugMode: Bool

    private enum CodingKeys: String, CodingKey {
        case cacheTtlSeconds, syncIntervalSeconds, maxOfflineEvents, maxBatchSize, enableOfflineMode, enableDebugMode
    }

    init(
        cacheTtlSeconds: Int = 300,
        syncIntervalSeconds: Int = 30,
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
        cacheTtlSeconds = (try? container.decodeIfPresent(Int.self, forKey: .cacheTtlSeconds)) ?? 300
        syncIntervalSeconds = (try? container.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds)) ?? 30
        maxOfflineEvents = (try? container.decodeIfPresent(Int.self, forKey: .maxOfflineEvents)) ?? 1000
        maxBatchSize = (try? container.decodeIfPresent(Int.self, forKey: .maxBatchSize)) ?? 100
        enableOfflineMode = (try? container.decodeIfPresent(Bool.self, forKey: .enableOfflineMode)) ?? true
        enableDebugMode = (try? container.decodeIfPresent(Bool.self, forKey: .enableDebugMode)) ?? false
    }
}

private struct SyncResponse: Decodable {
    let success: Bool
    let synced: Int
    let failed: Int
    let errors: [String]?
}

struct SyncResult {
    let synced: Int
    let failed: Int
    let errors: [String]?
}

private struct FlagsResponse: Decodable {
    let flags: [FeatureFlag]?
}
