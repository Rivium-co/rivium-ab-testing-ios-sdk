import XCTest
@testable import RiviumAbTesting

/// The send interval and the list cache the console sets, and the time on each event.
final class ServerSettingsTests: XCTestCase {
    private var service: FakeService { FakeService.shared }
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var recorder = Recorder()
    private var now = Box<TimeInterval>(1_760_000_000)
    private var sdks: [RiviumAbTesting] = []

    override func setUp() {
        super.setUp()
        service.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rivium-ab-tests-\(UUID().uuidString)")
        suiteName = "rivium-ab-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        recorder = Recorder()
        now = Box<TimeInterval>(1_760_000_000)
    }

    override func tearDown() {
        sdks.forEach { $0.reset() }
        sdks = []
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func start(flushInterval: TimeInterval? = nil, userToken: String? = nil) -> RiviumAbTesting {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        var environment = RiviumAbTesting.Environment()
        environment.defaults = defaults
        environment.sessionConfiguration = configuration
        environment.queueFileURL = directory.appendingPathComponent("support/pending_events.json")
        environment.legacyQueueFileURL = directory.appendingPathComponent("documents/pending_events.json")
        environment.observesNetwork = false
        environment.now = { [now] in now.value }

        let sdk = RiviumAbTesting(environment: environment)
        sdks.append(sdk)
        let recorder = Recorder()
        self.recorder = recorder
        let config: RiviumAbTestingConfig
        if let flushInterval = flushInterval {
            config = RiviumAbTestingConfig(apiKey: "rv_live_abcdef123456", flushInterval: flushInterval, maxQueueSize: 100_000, userToken: userToken)
        } else {
            config = RiviumAbTestingConfig(apiKey: "rv_live_abcdef123456", maxQueueSize: 100_000, userToken: userToken)
        }
        sdk.initialize(config: config, delegate: recorder)
        eventually { recorder.initialized > 0 }
        settle(0.15)
        return sdk
    }

    func testTheConsolesSendIntervalAndListCacheAreFollowed() {
        service.config = "{\"cacheTtlSeconds\":120,\"syncIntervalSeconds\":60}"
        let sdk = start()

        XCTAssertEqual(sdk.currentFlushInterval, 60)
        XCTAssertEqual(sdk.currentListCache, 120)
    }

    func testWithoutAnAnswerFromTheConsoleTheBuiltInValuesStay() {
        let sdk = start()

        XCTAssertEqual(sdk.currentFlushInterval, 30)
        XCTAssertEqual(sdk.currentListCache, 300)
    }

    func testAnIntervalTheAppPassedWinsOverTheConsoles() {
        service.config = "{\"cacheTtlSeconds\":120,\"syncIntervalSeconds\":60}"
        let own = start(flushInterval: 5)
        XCTAssertEqual(own.currentFlushInterval, 5)
        // The list cache has no option in the app: the console's value is used.
        XCTAssertEqual(own.currentListCache, 120)

        // Passing the built-in 30 seconds is a choice too.
        let thirty = start(flushInterval: 30)
        XCTAssertEqual(thirty.currentFlushInterval, 30)
    }

    func testTheConfigKeepsItsMeaningForExistingCode() {
        XCTAssertEqual(RiviumAbTestingConfig(apiKey: "k").flushInterval, 30)
        XCTAssertFalse(RiviumAbTestingConfig(apiKey: "k").hasOwnFlushInterval)
        XCTAssertFalse(RiviumAbTestingConfig.fromApiKey("k").hasOwnFlushInterval)
        let seconds: TimeInterval = 12.5
        XCTAssertEqual(RiviumAbTestingConfig(apiKey: "k", flushInterval: seconds).flushInterval, 12.5)
        XCTAssertTrue(RiviumAbTestingConfig(apiKey: "k", debug: true, flushInterval: 10.0, maxQueueSize: 5, autoTrack: false).hasOwnFlushInterval)
    }

    func testValuesOutOfBoundsAreBroughtInsideThem() {
        service.config = "{\"cacheTtlSeconds\":1,\"syncIntervalSeconds\":1}"
        let low = start()
        XCTAssertEqual(low.currentFlushInterval, 10)
        XCTAssertEqual(low.currentListCache, 60)

        service.config = "{\"cacheTtlSeconds\":99999999,\"syncIntervalSeconds\":99999999}"
        let high = start()
        XCTAssertEqual(high.currentFlushInterval, 3600)
        XCTAssertEqual(high.currentListCache, 86_400)

        service.config = "{\"cacheTtlSeconds\":0,\"syncIntervalSeconds\":-5}"
        let none = start()
        XCTAssertEqual(none.currentFlushInterval, 30)
        XCTAssertEqual(none.currentListCache, 300)

        service.config = "{\"cacheTtlSeconds\":\"soon\",\"syncIntervalSeconds\":12.5}"
        let odd = start()
        XCTAssertEqual(odd.currentFlushInterval, 30)
        XCTAssertEqual(odd.currentListCache, 300)
    }

    func testTheListIsReusedWhileItIsFreshAndAskedForAgainOnceItIsStale() {
        service.config = "{\"cacheTtlSeconds\":120,\"syncIntervalSeconds\":60}"
        let sdk = start(userToken: userToken("user-1"))
        let inits = service.to("/public/init").count

        now.value += 119
        for _ in 0..<5 { _ = sdk.getVariant(experimentKey: "checkout") }
        settle()
        XCTAssertEqual(service.to("/public/init").count, inits)

        // The console changed both values in the meantime.
        service.config = "{\"cacheTtlSeconds\":600,\"syncIntervalSeconds\":45}"
        now.value += 2
        for _ in 0..<5 { _ = sdk.getVariant(experimentKey: "checkout") }
        eventually { self.service.to("/public/init").count == inits + 1 }
        settle()

        // One request, however many callers; the new values are in use without a restart.
        XCTAssertEqual(service.to("/public/init").count, inits + 1)
        XCTAssertEqual(sdk.currentFlushInterval, 45)
        XCTAssertEqual(sdk.currentListCache, 600)

        now.value += 599
        _ = sdk.getVariant(experimentKey: "checkout")
        settle()
        XCTAssertEqual(service.to("/public/init").count, inits + 1)
    }

    func testARefreshThatFailsIsNotRepeatedOnEveryCallAndIsNotReportedAsAnError() {
        let sdk = start(userToken: userToken("user-1"))
        let inits = service.to("/public/init").count

        service.reads = { .json(500, "{}") }
        now.value += 301
        for _ in 0..<5 {
            _ = sdk.getVariant(experimentKey: "checkout")
            settle(0.06)
        }
        XCTAssertEqual(service.to("/public/init").count, inits + 1)
        XCTAssertTrue(recorder.errors.isEmpty)

        service.reads = { nil }
        now.value += 61
        _ = sdk.getVariant(experimentKey: "checkout")
        eventually { self.service.to("/public/init").count == inits + 2 }
    }

    func testTheAppsOwnIntervalKeepsDrivingTheTimer() {
        // The app chose one second; nothing the console says changes that timer.
        service.config = "{\"syncIntervalSeconds\":600}"
        let sdk = start(flushInterval: 1, userToken: userToken("user-1"))
        _ = sdk.getVariant(experimentKey: "checkout")
        eventually { !self.service.to("/public/assign").isEmpty }
        settle()
        sdk.trackClick(experimentKey: "checkout")
        eventually(4) { !self.service.to("/public/track/batch").isEmpty }
    }

    func testEveryEventCarriesTheTimeItWasRecordedInMilliseconds() {
        let sdk = start(userToken: userToken("user-1"))
        _ = sdk.getVariant(experimentKey: "checkout")
        eventually { !self.service.to("/public/assign").isEmpty }
        settle()

        let before = Date().timeIntervalSince1970 * 1000 - 1
        sdk.trackView(experimentKey: "checkout")
        Thread.sleep(forTimeInterval: 0.005)
        sdk.trackPurchase(experimentKey: "checkout", value: 9.5)
        let after = Date().timeIntervalSince1970 * 1000 + 1
        sdk.flush()
        eventually { !self.service.to("/public/track/batch").isEmpty }

        let times = service.trackedEvents.compactMap { ($0["timestamp"] as? NSNumber)?.doubleValue }
        XCTAssertEqual(times.count, 2)
        XCTAssertTrue(times.allSatisfy { $0 >= before && $0 <= after })
        XCTAssertLessThan(times[0], times[1])
    }
}
