import Foundation

internal class ApiClient {
    private let config: RiviumAbTestingConfig
    private let session: URLSession

    init(config: RiviumAbTestingConfig) {
        self.config = config

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    private var baseUrl: String {
        return RiviumAbTestingConfig.apiUrl
    }

    private var headers: [String: String] {
        return [
            "Content-Type": "application/json",
            "x-api-key": config.apiKey
        ]
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
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        session.dataTask(with: request) { data, response, error in
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
        }.resume()
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
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        session.dataTask(with: request) { data, response, error in
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
        }.resume()
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
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

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

        session.dataTask(with: request) { data, response, error in
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
        }.resume()
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
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

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

        session.dataTask(with: request) { data, response, error in
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
        }.resume()
    }

    // MARK: - Events

    /// Track events
    func trackEvents(_ events: [TrackEvent], completion: @escaping (Result<Void, RiviumAbTestingError>) -> Void) {
        guard let url = URL(string: "\(baseUrl)/public/track/batch") else {
            completion(.failure(.invalidConfig("Invalid API URL")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        do {
            let payload = ["events": events]
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(.networkError("Failed to encode request")))
            return
        }

        session.dataTask(with: request) { _, response, error in
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
        }.resume()
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
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

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

        session.dataTask(with: request) { data, response, error in
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
        }.resume()
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
