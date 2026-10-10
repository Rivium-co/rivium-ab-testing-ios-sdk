import XCTest
@testable import RiviumAbTesting

final class SDKTests: XCTestCase {
    private var service: FakeService { FakeService.shared }
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var recorder = Recorder()
    private var awaiting = Counter()
    private var sdks: [RiviumAbTesting] = []

    override func setUp() {
        super.setUp()
        service.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rivium-ab-tests-\(UUID().uuidString)")
        suiteName = "rivium-ab-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        recorder = Recorder()
        awaiting = Counter()
    }

    override func tearDown() {
        sdks.forEach { $0.reset() }
        sdks = []
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var queueFile: URL { directory.appendingPathComponent("support/pending_events.json") }
    private var legacyQueueFile: URL { directory.appendingPathComponent("documents/pending_events.json") }

    private func environment(providerTimeout: TimeInterval = 15) -> RiviumAbTesting.Environment {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        var environment = RiviumAbTesting.Environment()
        environment.defaults = defaults
        environment.sessionConfiguration = configuration
        environment.queueFileURL = queueFile
        environment.legacyQueueFileURL = legacyQueueFile
        environment.observesNetwork = false
        environment.tokenProviderTimeout = providerTimeout
        return environment
    }

    /// A started SDK, waited for until its first load is done.
    private func start(
        provider: RiviumTokenProvider? = nil,
        userToken: String? = nil,
        maxQueueSize: Int = 100_000,
        providerTimeout: TimeInterval = 15
    ) -> RiviumAbTesting {
        let sdk = RiviumAbTesting(environment: environment(providerTimeout: providerTimeout))
        sdks.append(sdk)
        sdk.onAwaitingUserToken = { [awaiting] in awaiting.next() }
        let config = RiviumAbTestingConfig(
            apiKey: "rv_live_abcdef123456",
            flushInterval: 3600, // the tests flush by hand
            maxQueueSize: maxQueueSize,
            tokenProvider: provider,
            userToken: userToken
        )
        sdk.initialize(config: config, delegate: recorder)
        eventually { recorder.initialized > 0 }
        settle(0.15)
        return sdk
    }

    private func variant(_ sdk: RiviumAbTesting, _ experimentKey: String = "checkout", default defaultVariant: String = "control") -> String {
        let done = expectation(description: "variant")
        var variant = ""
        sdk.getVariant(experimentKey: experimentKey, defaultVariant: defaultVariant) {
            variant = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return variant
    }

    private func assertEventsMatchTheirToken(file: StaticString = #filePath, line: UInt = #line) {
        for call in service.to("/public/track/batch") {
            let tokenUser = TokenClaims.subject(call.token)
            XCTAssertTrue(call.events.allSatisfy { $0["userId"] as? String == tokenUser }, file: file, line: line)
        }
    }

    // MARK: - Waiting for a user token

    func testWithoutATokenNothingIsSentForAUserTheDefaultIsReturnedAndTheEventIsKept() {
        let sdk = start()

        XCTAssertEqual(recorder.initialized, 1)
        XCTAssertTrue(sdk.isAwaitingUserToken)
        XCTAssertEqual(awaiting.value, 1)

        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout", defaultVariant: "fallback"), "fallback")
        XCTAssertEqual(variant(sdk, default: "fallback"), "fallback")
        sdk.trackClick(experimentKey: "checkout")
        sdk.flush()
        settle()

        XCTAssertEqual(sdk.pendingEventCount, 1)
        XCTAssertNil(sdk.getVariantConfig(experimentKey: "checkout"))
        XCTAssertTrue(service.userCalls.isEmpty)
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertEqual(awaiting.value, 1, "told once")
    }

    func testAProviderWithoutATokenAndThenWithOneFetchesTheAssignmentAndSendsTheKeptEvents() {
        let current = Box<String?>(nil)
        let sdk = start(provider: { completion in
            if let token = current.value { completion(.success(token)) } else { completion(.failure(URLError(.userAuthenticationRequired))) }
        })
        sdk.setUserId("alice")
        eventually { sdk.isAwaitingUserToken }

        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout"), "control")
        sdk.trackClick(experimentKey: "checkout")
        sdk.trackConversion(experimentKey: "checkout", value: 9.5)
        settle()
        XCTAssertTrue(service.userCalls.isEmpty)
        XCTAssertEqual(sdk.pendingEventCount, 2)

        let token = userToken("alice")
        current.value = token
        sdk.refreshUserToken()

        eventually { sdk.pendingEventCount == 0 }
        XCTAssertFalse(sdk.isAwaitingUserToken)
        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout"), "treatment")
        eventually { recorder.assigned == ["checkout=treatment"] }
        XCTAssertEqual(service.to("/public/assign").map { $0.token }, [token])

        let events = service.trackedEvents
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0["variantId"] as? String == "var-treatment" && $0["userId"] as? String == "alice" })
        XCTAssertTrue(events.allSatisfy { !(($0["clientEventId"] as? String) ?? "").isEmpty })
        XCTAssertTrue(service.to("/public/track/batch").allSatisfy { $0.token == token })
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testAProviderThatNeverAnswersDoesNotBlockTheSDK() {
        let sdk = start(provider: { _ in }, providerTimeout: 0.3)

        eventually { sdk.isAwaitingUserToken }
        XCTAssertEqual(recorder.initialized, 1)
        XCTAssertTrue(sdk.isFeatureEnabled("new-ui"))
        XCTAssertEqual(variant(sdk), "control")
        XCTAssertTrue(service.userCalls.isEmpty)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testSetUserTokenEndsTheWaitAndNilStartsItAgain() {
        let sdk = start()
        XCTAssertTrue(sdk.isAwaitingUserToken)
        _ = sdk.getVariant(experimentKey: "checkout")

        sdk.setUserToken(userToken("alice"))
        XCTAssertFalse(sdk.isAwaitingUserToken)
        XCTAssertEqual(sdk.getUserId(), "alice")
        eventually { sdk.getVariant(experimentKey: "checkout") == "treatment" }
        sdk.setUserAttributes(["plan": "pro"])
        sdk.trackClick(experimentKey: "checkout")

        sdk.setUserToken(nil)

        XCTAssertTrue(sdk.isAwaitingUserToken)
        eventually { awaiting.value == 2 }
        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout"), "control")
        XCTAssertNotEqual(sdk.getUserId(), "alice")
        XCTAssertNil(Storage(defaults: defaults).userAttributes)
        XCTAssertEqual(sdk.pendingEventCount, 0)
    }

    func testWhileWaitingTheProviderIsNotAskedOnEveryCall() {
        let calls = Counter()
        let sdk = start(provider: { completion in
            calls.next()
            completion(.failure(URLError(.userAuthenticationRequired)))
        })
        XCTAssertEqual(calls.value, 1)

        for _ in 0..<20 {
            _ = sdk.getVariant(experimentKey: "checkout")
            sdk.trackClick(experimentKey: "checkout")
            sdk.flush()
        }
        _ = variant(sdk)
        settle()

        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(service.userCalls.isEmpty)
    }

    func testEventsRecordedBeforeSignInAreSentOnlyForTheSameUserId() {
        let sdk = start()
        let anonymous = sdk.getUserId()
        _ = sdk.getVariant(experimentKey: "checkout")
        sdk.trackClick(experimentKey: "checkout")
        XCTAssertEqual(sdk.pendingEventCount, 1)

        sdk.setUserToken(userToken("alice"))

        eventually { sdk.getVariant(experimentKey: "checkout") == "treatment" }
        settle()
        XCTAssertNotEqual(anonymous, sdk.getUserId())
        XCTAssertEqual(sdk.pendingEventCount, 0)
        XCTAssertTrue(service.to("/public/track/batch").isEmpty)
    }

    func testAttributesSetBeforeSignInAreKeptForTheUserWhoSignsIn() {
        let sdk = start()
        sdk.setUserAttributes(["plan": "pro"])
        _ = sdk.getVariant(experimentKey: "checkout")

        sdk.setUserToken(userToken("alice"))

        eventually { !service.to("/public/assign").isEmpty }
        let attributes = service.to("/public/assign").first?.json["userAttributes"] as? [String: Any]
        XCTAssertEqual(attributes?["plan"] as? String, "pro")
    }

    func testSetUserIdKeepsTheAttributesOfAnAnonymousUserAndClearsAnotherUsers() {
        let sdk = start()
        sdk.setUserAttributes(["plan": "pro"])

        sdk.setUserId("alice")
        XCTAssertEqual(Storage(defaults: defaults).userAttributes?["plan"] as? String, "pro")

        sdk.setUserId("bob")
        XCTAssertNil(Storage(defaults: defaults).userAttributes)
    }

    func testAUserIdKeptByAnOlderVersionIsNotTakenForAnAnonymousOne() {
        let storage = Storage(defaults: defaults)
        storage.userId = "alice"
        XCTAssertFalse(storage.userIdGenerated)
        storage.userId = "3F2B8C1E-9D4A-4B7C-8E21-0A1B2C3D4E5F"
        XCTAssertTrue(storage.userIdGenerated)
    }

    // MARK: - What the service says about the token

    func testTokenRequiredPutsTheSDKInTheWaitingStateWithoutRetrying() {
        service.assign = { _ in .tokenError("token_required") }
        let sdk = start(userToken: "not-a-real-token")
        XCTAssertFalse(sdk.isAwaitingUserToken)

        XCTAssertEqual(variant(sdk), "control")
        XCTAssertTrue(sdk.isAwaitingUserToken)
        for _ in 0..<5 { _ = sdk.getVariant(experimentKey: "checkout") }
        sdk.trackClick(experimentKey: "checkout")
        sdk.flush()
        settle()

        XCTAssertEqual(service.to("/public/assign").count, 1)
        XCTAssertTrue(service.to("/public/track/batch").isEmpty)
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertEqual(awaiting.value, 1)
        XCTAssertEqual(sdk.pendingEventCount, 1)
    }

    func testTokenExpiredOneRefreshAndOneRetry() {
        let calls = Counter()
        let sdk = start(provider: { $0(.success(userToken("alice", salt: "\(calls.next())"))) })
        let answers = Counter()
        service.assign = { _ in answers.next() == 1 ? .tokenError("token_expired") : .assigned() }

        XCTAssertEqual(variant(sdk), "treatment")

        let assigns = service.to("/public/assign")
        XCTAssertEqual(assigns.count, 2)
        XCTAssertEqual(calls.value, 2)
        XCTAssertNotEqual(assigns[0].token, assigns[1].token)
        XCTAssertFalse(sdk.isAwaitingUserToken)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testTokenExpiredAndNoNewTokenTheSDKWaitsItDoesNotLoop() {
        let calls = Counter()
        let sdk = start(provider: { completion in
            if calls.next() == 1 { completion(.success(userToken("alice"))) } else { completion(.failure(URLError(.userAuthenticationRequired))) }
        })
        service.assign = { _ in .tokenError("token_expired") }

        XCTAssertEqual(variant(sdk), "control")
        settle()

        XCTAssertTrue(sdk.isAwaitingUserToken)
        XCTAssertEqual(service.to("/public/assign").count, 1)
        XCTAssertEqual(calls.value, 2)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testTokenExpiredAgainAfterTheRefreshIsNotRetriedForEver() {
        let calls = Counter()
        let sdk = start(provider: { $0(.success(userToken("alice", salt: "\(calls.next())"))) })
        service.assign = { _ in .tokenError("token_expired") }

        XCTAssertEqual(variant(sdk), "control")
        for _ in 0..<3 { _ = sdk.getVariant(experimentKey: "checkout") }
        settle()

        XCTAssertEqual(service.to("/public/assign").count, 2)
    }

    func testTokenInvalidIsReportedOnceAndNotRetried() {
        let sdk = start(userToken: userToken("alice"))
        service.assign = { _ in .tokenError("token_invalid") }

        XCTAssertEqual(variant(sdk), "control")
        for _ in 0..<5 { _ = sdk.getVariant(experimentKey: "checkout") }
        XCTAssertEqual(variant(sdk, "pricing"), "control")
        settle()

        XCTAssertEqual(service.to("/public/assign").count, 1)
        XCTAssertEqual(recorder.errors.count, 1)
        if case .apiError(let status, _)? = recorder.errors.first {
            XCTAssertEqual(status, 401)
        } else {
            XCTFail("expected an API error")
        }
        XCTAssertTrue(sdk.isAwaitingUserToken)
    }

    // MARK: - Users

    func testAfterAUserSwitchNothingOfTheFirstUserIsSentUnderTheSecondUsersToken() {
        let user = Box("alice")
        let sdk = start(provider: { $0(.success(userToken(user.value))) })
        XCTAssertEqual(sdk.getUserId(), "alice")
        XCTAssertEqual(variant(sdk), "treatment")
        sdk.setUserAttributes(["plan": "pro"])
        // The service is unreachable for alice's events, so they are still queued at the switch.
        service.track = { _ in .unreachable }
        sdk.trackClick(experimentKey: "checkout")
        sdk.trackClick(experimentKey: "checkout")

        user.value = "bob"
        service.track = { .tracked($0.events.count) }
        sdk.setUserId("bob")

        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout"), "control")
        eventually { sdk.getVariant(experimentKey: "checkout") == "treatment" }
        sdk.trackClick(experimentKey: "checkout")
        sdk.flush()
        eventually { service.trackedEvents.contains { $0["userId"] as? String == "bob" } }
        settle()

        XCTAssertNil(Storage(defaults: defaults).userAttributes?["plan"], "attributes are the first user's")
        assertEventsMatchTheirToken()
        XCTAssertTrue(service.to("/public/assign").dropFirst().allSatisfy { TokenClaims.subject($0.token) == "bob" })
    }

    func testATokenForAnotherUserIsAUserSwitch() {
        let sdk = start(userToken: userToken("alice"))
        XCTAssertEqual(variant(sdk), "treatment")
        sdk.setUserAttributes(["plan": "pro"])
        service.track = { _ in .json(500, "{}") }
        sdk.trackClick(experimentKey: "checkout")
        sdk.flush()
        eventually { service.to("/public/track/batch").count == 1 }
        service.track = { .tracked($0.events.count) }

        sdk.setUserToken(userToken("bob"))

        XCTAssertEqual(sdk.getUserId(), "bob")
        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout"), "control")
        XCTAssertNil(Storage(defaults: defaults).userAttributes)
        settle()
        assertEventsMatchTheirToken()
        XCTAssertEqual(sdk.pendingEventCount, 0)
    }

    func testClearUserIdSignsTheUserOut() {
        let sdk = start(userToken: userToken("alice"))
        XCTAssertEqual(variant(sdk), "treatment")

        sdk.clearUserId()

        XCTAssertTrue(sdk.isAwaitingUserToken)
        XCTAssertNotNil(sdk.getUserId())
        XCTAssertNotEqual(sdk.getUserId(), "alice")
        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout"), "control")
        let before = service.userCalls.count
        sdk.trackClick(experimentKey: "checkout")
        sdk.flush()
        settle()
        XCTAssertEqual(service.userCalls.count, before)
    }

    // MARK: - Variants

    func test201And200AreBothASuccess() {
        service.assign = { call in
            (call.json["experimentKey"] as? String) == "pricing"
                ? .assigned(201, experimentId: "exp-2", experimentKey: "pricing", variantKey: "b")
                : .assigned(200)
        }
        let sdk = start(userToken: userToken("alice"))

        XCTAssertEqual(variant(sdk, "checkout"), "treatment")
        XCTAssertEqual(variant(sdk, "pricing"), "b")
        XCTAssertEqual(sdk.getVariantConfig(experimentKey: "pricing")?["color"] as? String, "blue")
    }

    func testGetVariantDoesNotWaitForTheService() {
        service.assign = { _ in
            var answer = Answer.assigned()
            answer.delay = 0.7
            return answer
        }
        let sdk = start(userToken: userToken("alice"))

        let started = Date()
        let first = sdk.getVariant(experimentKey: "checkout")
        let took = Date().timeIntervalSince(started)

        XCTAssertEqual(first, "control")
        XCTAssertLessThan(took, 0.3)
        eventually { sdk.getVariant(experimentKey: "checkout") == "treatment" }
        XCTAssertEqual(service.to("/public/assign").count, 1)
    }

    func testNoVariantIsMadeUpOnTheDeviceWhenTheServiceCannotBeAsked() {
        service.assign = { _ in .json(500, "{}") }
        let sdk = start(userToken: userToken("alice"))

        XCTAssertEqual(variant(sdk), "control")
        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout"), "control")
        XCTAssertNil(sdk.getVariantConfig(experimentKey: "checkout"))
        XCTAssertTrue(recorder.assigned.isEmpty)
    }

    func testAUserOutsideTheExperimentGetsTheControlAndNoEvents() {
        service.assign = { _ in .assigned(variantKey: "control", inExperiment: false) }
        let sdk = start(userToken: userToken("alice"))

        XCTAssertEqual(variant(sdk, default: "fallback"), "control")
        sdk.trackClick(experimentKey: "checkout")
        sdk.flush()
        settle()

        XCTAssertEqual(sdk.pendingEventCount, 0)
        XCTAssertTrue(service.to("/public/track/batch").isEmpty)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testAnAnswerWithoutInExperimentIsAnAssignment() {
        service.assign = { _ in .assigned(inExperiment: nil) }
        let sdk = start(userToken: userToken("alice"))

        XCTAssertEqual(variant(sdk), "treatment")
        sdk.trackClick(experimentKey: "checkout")
        sdk.flush()
        eventually { service.trackedEvents.count == 1 }
    }

    // MARK: - The event queue

    func testTheQueueKeepsTheNewest1000Events() {
        let sdk = start()
        _ = sdk.getVariant(experimentKey: "checkout")

        for _ in 0..<1100 { sdk.trackClick(experimentKey: "checkout") }

        XCTAssertEqual(sdk.pendingEventCount, 1000)
        XCTAssertTrue(service.userCalls.isEmpty)
    }

    func testEventsAreSent100AtATimeAndEachOneOnce() {
        let sdk = start(userToken: userToken("alice"))
        XCTAssertEqual(variant(sdk), "treatment")
        service.track = { call in
            var answer = Answer.tracked(call.events.count)
            answer.delay = 0.05
            return answer
        }

        for _ in 0..<250 { sdk.trackClick(experimentKey: "checkout") }
        for _ in 0..<3 { sdk.flush() }

        eventually { sdk.pendingEventCount == 0 }
        settle()
        XCTAssertEqual(service.to("/public/track/batch").map { $0.events.count }, [100, 100, 50])
        let ids = service.trackedEvents.compactMap { $0["clientEventId"] as? String }
        XCTAssertEqual(Set(ids).count, 250)
    }

    func testARefusedChunkIsDroppedAndTheRestIsStillSent() {
        let sdk = start(userToken: userToken("alice"))
        XCTAssertEqual(variant(sdk), "treatment")
        let answers = Counter()
        service.track = { call in
            answers.next() == 1 ? .json(400, "{\"statusCode\":400,\"message\":\"Bad Request\"}") : .tracked(call.events.count)
        }

        for _ in 0..<150 { sdk.trackClick(experimentKey: "checkout") }
        sdk.flush()

        eventually { sdk.pendingEventCount == 0 }
        XCTAssertEqual(service.to("/public/track/batch").map { $0.events.count }, [100, 50])
    }

    func test429IsHonouredNothingIsSentBeforeRetryAfterHasPassed() {
        let sdk = start(userToken: userToken("alice"))
        XCTAssertEqual(variant(sdk), "treatment")
        let answers = Counter()
        service.track = { call in
            answers.next() == 1
                ? Answer(status: 429, body: "{\"statusCode\":429,\"message\":\"Too many requests\"}", headers: ["Retry-After": "2"])
                : .tracked(call.events.count)
        }
        sdk.trackClick(experimentKey: "checkout")

        sdk.flush()
        eventually { service.to("/public/track/batch").count == 1 }
        for _ in 0..<5 {
            sdk.flush()
            sdk.trackClick(experimentKey: "checkout")
        }
        XCTAssertEqual(variant(sdk, "pricing"), "control")
        settle()
        XCTAssertEqual(service.to("/public/track/batch").count, 1)
        XCTAssertEqual(service.to("/public/assign").count, 1)
        XCTAssertEqual(sdk.pendingEventCount, 6)

        settle(2)
        sdk.flush()
        eventually { sdk.pendingEventCount == 0 }
        XCTAssertEqual(service.to("/public/track/batch").count, 2)
    }

    func testTheMonthlyEventLimitKeepsTheEventsAndStopsSending() {
        let sdk = start(userToken: userToken("alice"), maxQueueSize: 1)
        XCTAssertEqual(variant(sdk), "treatment")
        service.track = { _ in .json(403, "{\"statusCode\":403,\"code\":\"event_limit_reached\",\"message\":\"Event limit reached\"}") }

        for _ in 0..<10 { sdk.trackClick(experimentKey: "checkout") }
        sdk.flush()
        settle()

        XCTAssertEqual(service.to("/public/track/batch").count, 1)
        XCTAssertEqual(sdk.pendingEventCount, 10)
        XCTAssertTrue(recorder.errors.isEmpty)
    }

    func testAServerErrorIsRetriedLaterNotAtOnce() {
        let sdk = start(userToken: userToken("alice"), maxQueueSize: 1)
        XCTAssertEqual(variant(sdk), "treatment")
        service.track = { _ in .json(503, "{}") }

        for _ in 0..<10 { sdk.trackClick(experimentKey: "checkout") }
        for _ in 0..<3 { sdk.flush() }
        settle()

        XCTAssertEqual(service.to("/public/track/batch").count, 1)
        XCTAssertEqual(sdk.pendingEventCount, 10)
    }

    func testQueuedEventsSurviveARestartInApplicationSupport() {
        let first = start()
        first.setUserId("alice")
        _ = first.getVariant(experimentKey: "checkout")
        first.trackClick(experimentKey: "checkout")
        first.waitForDisk()
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyQueueFile.path))

        let second = RiviumAbTesting(environment: environment())
        sdks.append(second)
        second.initialize(config: RiviumAbTestingConfig(apiKey: "rv_live_abcdef123456", flushInterval: 3600, userToken: userToken("alice")))

        eventually { service.trackedEvents.count == 1 && second.pendingEventCount == 0 }
        XCTAssertEqual(service.trackedEvents.first?["variantId"] as? String, "var-treatment")
    }

    func testTheOldQueueFileInDocumentsIsMovedOnce() throws {
        // What 0.2.1 wrote: no clientEventId.
        let old = "[{\"experimentId\":\"exp-1\",\"variantId\":\"var-treatment\",\"userId\":\"alice\",\"eventType\":\"click\",\"timestamp\":1700000000000}]"
        try FileManager.default.createDirectory(at: legacyQueueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: legacyQueueFile)
        defaults.set("alice", forKey: "rivium_ab_testing_user_id")

        let sdk = start(userToken: userToken("alice"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyQueueFile.path))
        eventually { service.trackedEvents.count == 1 }
        XCTAssertEqual(service.trackedEvents.first?["userId"] as? String, "alice")
        XCTAssertFalse(((service.trackedEvents.first?["clientEventId"] as? String) ?? "").isEmpty)
        XCTAssertEqual(sdk.pendingEventCount, 0)
    }

    // MARK: - Start-up

    func testUsedBeforeInitializeNothingCrashesAndDefaultsComeBack() {
        let sdk = RiviumAbTesting(environment: environment())

        sdk.setUserId("alice")
        sdk.setUserAttributes(["plan": "pro"])
        sdk.setUserToken(userToken("alice"))
        sdk.refreshUserToken()
        sdk.clearUserId()
        sdk.trackPurchase(experimentKey: "checkout", value: 10)
        sdk.flush()

        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout", defaultVariant: "fallback"), "fallback")
        XCTAssertEqual(variant(sdk, default: "fallback"), "fallback")
        XCTAssertNil(sdk.getVariantConfig(experimentKey: "checkout"))
        XCTAssertTrue(sdk.isFeatureEnabled("new-ui", defaultValue: true))
        XCTAssertEqual(sdk.getFeatureValue("new-ui", defaultValue: 7) as? Int, 7)
        XCTAssertFalse(sdk.isAwaitingUserToken)
        XCTAssertNil(sdk.getUserId())
        XCTAssertTrue(service.calls.isEmpty)
    }

    func testAFailedFirstLoadLeavesAWorkingSDKThatCanLoadAgain() {
        service.reads = { .json(503, "{}") }
        let sdk = start(userToken: userToken("alice"))

        XCTAssertEqual(sdk.getVariant(experimentKey: "checkout"), "control")
        XCTAssertFalse(sdk.isFeatureEnabled("new-ui"))
        sdk.trackClick(experimentKey: "checkout")

        service.reads = { nil }
        sdk.initialize(config: RiviumAbTestingConfig(apiKey: "rv_live_abcdef123456"))

        eventually { sdk.isFeatureEnabled("new-ui") }
        XCTAssertEqual(variant(sdk), "treatment")
        XCTAssertEqual(service.to("/public/assign").count, 1)
    }

    func testInitializeTwiceKeepsOneQueue() {
        let sdk = start(userToken: userToken("alice"))
        sdk.initialize(config: RiviumAbTestingConfig(apiKey: "rv_live_abcdef123456", userToken: userToken("alice")), delegate: recorder)
        XCTAssertEqual(variant(sdk), "treatment")

        for _ in 0..<5 { sdk.trackClick(experimentKey: "checkout") }
        sdk.flush()

        eventually { sdk.pendingEventCount == 0 }
        settle()
        XCTAssertEqual(service.trackedEvents.count, 5)
    }

    func testFlagEvaluationNeedsATokenTooAndFallsBackToTheLocalAnswer() {
        let sdk = start()
        let done = expectation(description: "flag")
        sdk.isFeatureEnabled("new-ui", defaultValue: false) { enabled in
            XCTAssertTrue(enabled)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertTrue(service.to("/public/flag-evaluation").isEmpty)
    }
}
