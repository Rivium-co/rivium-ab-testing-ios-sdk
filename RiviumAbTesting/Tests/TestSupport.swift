import XCTest
@testable import RiviumAbTesting

/// A token shaped like the real one: only `sub` and `exp` matter to the SDK.
func userToken(_ sub: String, expiresIn: TimeInterval = 3600, salt: String = "") -> String {
    let exp = Int(Date().timeIntervalSince1970 + expiresIn)
    let payload = Data("{\"sub\":\"\(sub)\",\"exp\":\(exp)}".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature\(salt)"
}

struct Call {
    let path: String
    let token: String?
    let body: Data

    var json: [String: Any] {
        return ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
    }

    var events: [[String: Any]] {
        return (json["events"] as? [[String: Any]]) ?? []
    }
}

struct Answer {
    var status: Int
    var body: String
    var headers: [String: String] = [:]
    var delay: TimeInterval = 0

    static func json(_ status: Int, _ body: String) -> Answer {
        return Answer(status: status, body: body)
    }

    static func tokenError(_ code: String) -> Answer {
        return .json(401, "{\"statusCode\":401,\"error\":\"Unauthorized\",\"code\":\"\(code)\",\"message\":\"\(code)\"}")
    }

    static func assigned(
        _ status: Int = 200,
        experimentId: String = "exp-1",
        experimentKey: String = "checkout",
        variantKey: String = "treatment",
        inExperiment: Bool? = true
    ) -> Answer {
        let extra = inExperiment.map { ",\"inExperiment\":\($0)" } ?? ""
        return .json(status, "{\"data\":{\"experimentId\":\"\(experimentId)\",\"experimentKey\":\"\(experimentKey)\","
            + "\"variantId\":\"var-\(variantKey)\",\"variantKey\":\"\(variantKey)\",\"variantName\":\"T\","
            + "\"config\":{\"color\":\"blue\"},\"isControl\":false,\"isNew\":true\(extra)}}")
    }

    static func tracked(_ count: Int) -> Answer {
        return .json(200, "{\"success\":true,\"tracked\":\(count),\"eventIds\":[],\"duplicates\":0,\"ignored\":0}")
    }

    /// No answer at all (no network).
    static let unreachable = Answer(status: 0, body: "")
}

/// Stands in for the service: answers by route and records what was sent.
final class FakeService {
    static let shared = FakeService()

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var readsHandler: () -> Answer? = { nil }
    private var assignHandler: (Call) -> Answer = { _ in .assigned() }
    private var trackHandler: (Call) -> Answer = { .tracked($0.events.count) }

    static let initBody = "{\"experiments\":["
        + "{\"id\":\"exp-1\",\"key\":\"checkout\",\"name\":\"Checkout\",\"trafficAllocation\":100,\"variants\":[]},"
        + "{\"id\":\"exp-2\",\"key\":\"pricing\",\"name\":\"Pricing\",\"trafficAllocation\":100,\"variants\":[]}"
        + "],\"config\":{}}"
    static let flagsBody = "{\"flags\":[{\"id\":\"f1\",\"key\":\"new-ui\",\"name\":\"New UI\",\"enabled\":true,\"rolloutPercentage\":100}]}"

    func reset() {
        lock.lock()
        recorded = []
        readsHandler = { nil }
        assignHandler = { _ in .assigned() }
        trackHandler = { .tracked($0.events.count) }
        lock.unlock()
    }

    var reads: () -> Answer? {
        get { lock.lock(); defer { lock.unlock() }; return readsHandler }
        set { lock.lock(); readsHandler = newValue; lock.unlock() }
    }

    var assign: (Call) -> Answer {
        get { lock.lock(); defer { lock.unlock() }; return assignHandler }
        set { lock.lock(); assignHandler = newValue; lock.unlock() }
    }

    var track: (Call) -> Answer {
        get { lock.lock(); defer { lock.unlock() }; return trackHandler }
        set { lock.lock(); trackHandler = newValue; lock.unlock() }
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func to(_ path: String) -> [Call] {
        return calls.filter { $0.path == path }
    }

    /// Calls that act for a user: none of these may happen without a user token.
    var userCalls: [Call] {
        return calls.filter { ["/public/assign", "/public/track/batch", "/public/flag-evaluation"].contains($0.path) }
    }

    var trackedEvents: [[String: Any]] {
        return to("/public/track/batch").flatMap { $0.events }
    }

    func answer(_ call: Call) -> Answer {
        lock.lock()
        recorded.append(call)
        let reads = readsHandler
        let assign = assignHandler
        let track = trackHandler
        lock.unlock()

        switch call.path {
        case "/public/init": return reads() ?? .json(200, Self.initBody)
        case "/public/flags": return reads() ?? .json(200, Self.flagsBody)
        case "/public/assign": return assign(call)
        case "/public/track/batch": return track(call)
        case "/public/flag-evaluation": return .json(200, "{\"flagKey\":\"new-ui\",\"enabled\":true}")
        default: return .json(404, "{}")
        }
    }
}

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let call = Call(
            path: request.url?.path ?? "",
            token: request.value(forHTTPHeaderField: "x-user-token"),
            body: body
        )
        let answer = FakeService.shared.answer(call)

        let deliver = { [weak self] in
            guard let self = self else { return }
            guard answer.status != 0 else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(
                url: self.request.url!,
                statusCode: answer.status,
                httpVersion: nil,
                headerFields: answer.headers
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if answer.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + answer.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

final class Recorder: RiviumAbTestingDelegate {
    private let lock = NSLock()
    private var _initialized = 0
    private var _errors: [RiviumAbTestingError] = []
    private var _assigned: [String] = []

    var initialized: Int { lock.lock(); defer { lock.unlock() }; return _initialized }
    var errors: [RiviumAbTestingError] { lock.lock(); defer { lock.unlock() }; return _errors }
    var assigned: [String] { lock.lock(); defer { lock.unlock() }; return _assigned }

    func riviumAbTestingDidInitialize() {
        lock.lock(); _initialized += 1; lock.unlock()
    }

    func riviumAbTesting(didReceiveError error: RiviumAbTestingError) {
        lock.lock(); _errors.append(error); lock.unlock()
    }

    func riviumAbTesting(didAssignVariant variantKey: String, forExperiment experimentKey: String, config: [String: Any]?) {
        lock.lock(); _assigned.append("\(experimentKey)=\(variantKey)"); lock.unlock()
    }
}

/// A counter that is safe to touch from the SDK's threads.
final class Counter {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class Box<T> {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

extension XCTestCase {
    /// Waits, with the main run loop turning, until `condition` holds.
    func eventually(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    /// Gives background work a moment, for asserting that something did NOT happen.
    func settle(_ seconds: TimeInterval = 0.25) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
