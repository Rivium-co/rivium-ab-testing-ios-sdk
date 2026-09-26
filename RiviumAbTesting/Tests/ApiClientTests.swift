import XCTest
@testable import RiviumAbTesting

/// Answers requests from a script, recording what was sent.
final class MockURLProtocol: URLProtocol {
    static var responses: [(Int, String)] = []
    static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ responses: [(Int, String)]) {
        lock.lock(); defer { lock.unlock() }
        self.responses = responses
        self.requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let (status, body) = Self.responses.isEmpty ? (200, "{}") : Self.responses.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ApiClientTests: XCTestCase {
    private func token(_ sub: String, expiresIn: TimeInterval = 3600) -> String {
        let exp = Int(Date().timeIntervalSince1970 + expiresIn)
        let payload = Data("{\"sub\":\"\(sub)\",\"exp\":\(exp)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func client(provider: RiviumTokenProvider? = nil, userToken: String? = nil) -> ApiClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let config = RiviumAbTestingConfig(apiKey: "rv_live_abcdef123456", tokenProvider: provider, userToken: userToken)
        return ApiClient(config: config, sessionConfiguration: configuration)
    }

    private func fetchFlags(_ api: ApiClient) -> Result<[FeatureFlag], RiviumAbTestingError> {
        let done = expectation(description: "request")
        var outcome: Result<[FeatureFlag], RiviumAbTestingError>!
        api.fetchFeatureFlags { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return outcome
    }

    func testSendsApiKeyAndNoTokenWithoutProvider() {
        MockURLProtocol.reset([(200, "{\"flags\":[]}")])
        let api = client()

        _ = fetchFlags(api)

        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "x-api-key"), "rv_live_abcdef123456")
        XCTAssertNil(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "x-user-token"))
        XCTAssertFalse(api.usesUserToken)
    }

    func testReusesAFreshTokenAndCoalescesProviderCalls() {
        MockURLProtocol.reset([(200, "{\"flags\":[]}"), (200, "{\"flags\":[]}")])
        var calls = 0
        let api = client(provider: { completion in
            calls += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                completion(.success(self.token("alice")))
            }
        })

        // Two requests at once must share one provider call.
        let both = expectation(description: "both")
        both.expectedFulfillmentCount = 2
        api.fetchFeatureFlags { _ in both.fulfill() }
        api.fetchFeatureFlags { _ in both.fulfill() }
        wait(for: [both], timeout: 5)
        _ = fetchFlags(api)

        XCTAssertEqual(calls, 1)
        let tokens = MockURLProtocol.requests.map { $0.value(forHTTPHeaderField: "x-user-token") }
        XCTAssertEqual(Set(tokens.compactMap { $0 }).count, 1)
        XCTAssertEqual(tokens.count, 3)
    }

    func testRefetchesATokenAboutToExpire() {
        MockURLProtocol.reset([(200, "{\"flags\":[]}"), (200, "{\"flags\":[]}")])
        var calls = 0
        let api = client(provider: { completion in
            calls += 1
            completion(.success(self.token("alice", expiresIn: 30)))
        })

        _ = fetchFlags(api)
        _ = fetchFlags(api)

        XCTAssertEqual(calls, 2)
    }

    func testTokenExpiredRefetchesAndRetriesOnce() {
        MockURLProtocol.reset([(401, "{\"code\":\"token_expired\"}"), (200, "{\"flags\":[]}")])
        var calls = 0
        let api = client(provider: { completion in
            calls += 1
            completion(.success(self.token("alice")))
        })

        let result = fetchFlags(api)

        if case .failure(let error) = result { XCTFail("expected success, got \(error)") }
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertEqual(calls, 2)
    }

    func testDoesNotRetryForever() {
        MockURLProtocol.reset([(401, "{\"code\":\"token_expired\"}"), (401, "{\"code\":\"token_expired\"}"), (401, "{\"code\":\"token_expired\"}")])
        let api = client(provider: { completion in completion(.success(self.token("alice"))) })

        let result = fetchFlags(api)

        guard case .failure = result else { return XCTFail("expected failure") }
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testClearTokenGetsATokenForTheNextUser() {
        MockURLProtocol.reset([(200, "{\"flags\":[]}"), (200, "{\"flags\":[]}")])
        var user = "alice"
        let api = client(provider: { completion in completion(.success(self.token(user))) })

        _ = fetchFlags(api)
        user = "bob"
        api.clearToken()
        _ = fetchFlags(api)

        let tokens = MockURLProtocol.requests.compactMap { $0.value(forHTTPHeaderField: "x-user-token") }
        XCTAssertEqual(tokens.count, 2)
        XCTAssertNotEqual(tokens[0], tokens[1])
    }

    func testExplicitTokenIsSentWithoutAskingTheProvider() {
        MockURLProtocol.reset([(200, "{}")])
        var calls = 0
        let api = client(provider: { completion in calls += 1; completion(.success(self.token("bob"))) })
        let aliceToken = token("alice")
        let event = TrackEvent(experimentId: "e", variantId: "v", userId: "alice", eventType: .view)

        let done = expectation(description: "track")
        api.trackEvents([event], explicitToken: .some(aliceToken)) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "x-user-token"), aliceToken)
        XCTAssertEqual(calls, 0)
    }

    func testAFailingProviderDoesNotBreakTheRequest() {
        MockURLProtocol.reset([(200, "{\"flags\":[]}")])
        let api = client(provider: { completion in
            completion(.failure(NSError(domain: "test", code: 1)))
        })

        let result = fetchFlags(api)

        if case .failure(let error) = result { XCTFail("expected success, got \(error)") }
        XCTAssertNil(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "x-user-token"))
    }
}
