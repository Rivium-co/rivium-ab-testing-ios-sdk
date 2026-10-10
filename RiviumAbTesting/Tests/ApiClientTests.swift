import XCTest
@testable import RiviumAbTesting

final class ApiClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FakeService.shared.reset()
    }

    private func client() -> ApiClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return ApiClient(config: RiviumAbTestingConfig(apiKey: "rv_live_abcdef123456"), sessionConfiguration: configuration)
    }

    private func fetch(_ tokens: UserTokens) -> String? {
        let done = expectation(description: "token")
        var token: String?
        tokens.fetch {
            token = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return token
    }

    // MARK: - Requests

    func testReadsSendTheApiKeyAndNoUserToken() {
        let api = client()
        let done = expectation(description: "reads")
        done.expectedFulfillmentCount = 2
        api.fetchFeatureFlags { result in
            if case .failure(let failure) = result { XCTFail("expected success, got \(failure)") }
            done.fulfill()
        }
        api.fetchExperiments { result in
            XCTAssertEqual((try? result.get())?.count, 2)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(FakeService.shared.calls.count, 2)
        XCTAssertTrue(FakeService.shared.calls.allSatisfy { $0.token == nil })
    }

    func testAUserCallSendsTheTokenItIsGivenAndAStableEventId() {
        let api = client()
        let token = userToken("alice")
        let event = TrackEvent(experimentId: "e", variantId: "v", userId: "alice", eventType: .view)

        let done = expectation(description: "track")
        api.trackEvents([event], token: token) { result in
            if case .failure(let failure) = result { XCTFail("expected success, got \(failure)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let call = FakeService.shared.to("/public/track/batch").first
        XCTAssertEqual(call?.token, token)
        XCTAssertEqual(call?.events.first?["clientEventId"] as? String, event.clientEventId)
        XCTAssertFalse(event.clientEventId.isEmpty)
    }

    func testErrorCodeAndRetryAfterAreReadFromTheAnswer() {
        let answers = Counter()
        FakeService.shared.assign = { _ in
            answers.next() == 1
                ? Answer(status: 429, body: "{\"statusCode\":429,\"message\":\"Too many requests\"}", headers: ["Retry-After": "7"])
                : .json(401, "{\"statusCode\":401,\"code\":\"token_required\",\"message\":\"A signed user token is required\"}")
        }
        let api = client()
        var failures: [ApiFailure] = []

        for _ in 0..<2 {
            let done = expectation(description: "assign")
            api.getAssignment(experimentKey: "checkout", userId: "alice", userAttributes: nil, token: "t") { result in
                if case .failure(let failure) = result { failures.append(failure) }
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }

        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(failures[0].status, 429)
        XCTAssertEqual(failures[0].retryAfter, 7)
        XCTAssertEqual(failures[1].code, "token_required")
        XCTAssertEqual(failures[1].message, "A signed user token is required")
    }

    func testNoAnswerIsAFailureWithoutAStatus() {
        FakeService.shared.reads = { .unreachable }
        let done = expectation(description: "flags")
        client().fetchFeatureFlags { result in
            guard case .failure(let failure) = result else { return XCTFail("expected failure") }
            XCTAssertNil(failure.status)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: - The user token

    func testTheProviderIsAskedOnceWhileItsTokenIsFresh() {
        let calls = Counter()
        let tokens = UserTokens(provider: { completion in
            calls.next()
            completion(.success(userToken("alice")))
        }, userToken: nil)

        let first = fetch(tokens)
        let second = tokens.held() ?? fetch(tokens)

        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(first, second)
    }

    func testATokenAboutToExpireIsFetchedAgain() {
        let calls = Counter()
        let tokens = UserTokens(provider: { completion in
            calls.next()
            completion(.success(userToken("alice", expiresIn: 30)))
        }, userToken: nil)

        _ = fetch(tokens)
        XCTAssertNil(tokens.held())
        _ = fetch(tokens)

        XCTAssertEqual(calls.value, 2)
    }

    func testCallersAtTheSameMomentShareOneProviderCall() {
        let calls = Counter()
        let tokens = UserTokens(provider: { completion in
            calls.next()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                completion(.success(userToken("alice")))
            }
        }, userToken: nil)

        let all = expectation(description: "all")
        all.expectedFulfillmentCount = 4
        for _ in 0..<4 {
            tokens.fetch { token in
                XCTAssertNotNil(token)
                all.fulfill()
            }
        }
        wait(for: [all], timeout: 5)

        XCTAssertEqual(calls.value, 1)
    }

    func testAProviderThatFailsMeansNoToken() {
        let failing = UserTokens(provider: { $0(.failure(NSError(domain: "test", code: 1))) }, userToken: nil)
        let empty = UserTokens(provider: { $0(.success("")) }, userToken: nil)
        let none = UserTokens(provider: nil, userToken: nil)

        XCTAssertNil(fetch(failing))
        XCTAssertNil(fetch(empty))
        XCTAssertNil(fetch(none))
    }

    func testAProviderThatNeverAnswersTimesOutAndCanBeAskedAgain() {
        let calls = Counter()
        let tokens = UserTokens(provider: { completion in
            if calls.next() > 1 { completion(.success(userToken("alice"))) }
        }, userToken: nil, providerTimeout: 0.2)

        let started = Date()
        XCTAssertNil(fetch(tokens))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        XCTAssertNotNil(fetch(tokens))
    }

    func testATokenTheAppSetWinsAndNilTakesEveryTokenAway() {
        let tokens = UserTokens(provider: { $0(.success(userToken("alice"))) }, userToken: nil)
        _ = fetch(tokens)

        let pushed = userToken("alice", salt: "2")
        tokens.set(pushed)
        XCTAssertEqual(tokens.held(), pushed)

        tokens.set(nil)
        XCTAssertNil(tokens.peek())
    }

    func testTokensForAnotherUserAreDroppedOnAUserChange() {
        let tokens = UserTokens(provider: nil, userToken: userToken("alice"))

        tokens.dropTokensNotFor("alice")
        XCTAssertNotNil(tokens.held())

        tokens.dropTokensNotFor("bob")
        XCTAssertNil(tokens.held())
    }
}
