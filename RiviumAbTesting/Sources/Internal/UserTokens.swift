import Foundation

/// Reads the two claims the SDK needs from a user token. The service verifies
/// the token; the SDK does not.
internal enum TokenClaims {
    /// The user the token is for (`sub`), or nil if unreadable.
    static func subject(_ token: String?) -> String? {
        guard let sub = payload(token)?["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    /// `exp` in seconds since 1970; 0 (fetch again next time) if unreadable.
    static func expiry(_ token: String?) -> TimeInterval {
        return (payload(token)?["exp"] as? NSNumber)?.doubleValue ?? 0
    }

    private static func payload(_ token: String?) -> [String: Any]? {
        guard let parts = token?.split(separator: "."), parts.count > 1 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// The user token: one the app set itself, or one fetched through the
/// provider. Held in memory only.
internal final class UserTokens {
    /// Fetch a new token this many seconds before the current one expires.
    private static let refreshSkew: TimeInterval = 60
    /// While the provider has no token it is not asked more often than this.
    private static let retryInterval: TimeInterval = 30

    private let provider: RiviumTokenProvider?
    /// A provider that never calls back counts as "no token" after this long.
    private let providerTimeout: TimeInterval

    private let lock = NSLock()
    private var pushedToken: String?
    private var cachedToken: String?
    private var cachedTokenExpiresAt: TimeInterval = 0
    private var waiters: [(String?) -> Void] = []
    private var fetchId = 0
    private var lastAskedAt: TimeInterval = 0

    init(provider: RiviumTokenProvider?, userToken: String?, providerTimeout: TimeInterval = 15) {
        self.provider = provider
        self.providerTimeout = providerTimeout
        self.pushedToken = (userToken?.isEmpty == false) ? userToken : nil
    }

    /// True when the app gave a token provider.
    var hasProvider: Bool { provider != nil }

    /// A token the app hands over itself; nil takes it away, with any fetched one.
    func set(_ token: String?) {
        lock.lock()
        defer { lock.unlock() }
        pushedToken = (token?.isEmpty == false) ? token : nil
        if pushedToken == nil {
            cachedToken = nil
            cachedTokenExpiresAt = 0
        }
    }

    /// Forget every token, e.g. when the user signs out.
    func clear() {
        set(nil)
    }

    /// Forget `token` if it is still the one held: the service said it expired or refused it.
    func invalidate(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        if cachedToken == token {
            cachedToken = nil
            cachedTokenExpiresAt = 0
        }
        if pushedToken == token { pushedToken = nil }
    }

    /// Forget the fetched token so the provider is asked again; a token the app set itself stays.
    func forgetFetched() {
        lock.lock()
        defer { lock.unlock() }
        cachedToken = nil
        cachedTokenExpiresAt = 0
    }

    /// Forget the tokens that are for someone other than `userId`. A token
    /// that cannot be read is the app's own business and stays.
    func dropTokensNotFor(_ userId: String) {
        lock.lock()
        defer { lock.unlock() }
        if TokenClaims.subject(cachedToken) != userId {
            cachedToken = nil
            cachedTokenExpiresAt = 0
        }
        if let pushedFor = TokenClaims.subject(pushedToken), pushedFor != userId {
            pushedToken = nil
        }
    }

    /// The token held right now, even one about to expire, without asking the provider.
    func peek() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pushedToken ?? cachedToken
    }

    /// The token to send right now, without asking the provider; nil when one must be fetched first.
    func held() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return heldLocked()
    }

    private func heldLocked() -> String? {
        if let token = pushedToken { return token }
        if let token = cachedToken, cachedTokenExpiresAt - Self.refreshSkew > Date().timeIntervalSince1970 {
            return token
        }
        return nil
    }

    /// False right after the provider was asked: while it has no token it is not asked on every call.
    var mayAskAgain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince1970 - lastAskedAt >= Self.retryInterval
    }

    /// Counts as having just asked the provider.
    func markAsked() {
        lock.lock()
        lastAskedAt = Date().timeIntervalSince1970
        lock.unlock()
    }

    /// Asks the provider for a token. Nil when there is no provider, it
    /// failed, or it did not answer in time: no one is signed in. Callers
    /// that arrive while a call is running share its result.
    func fetch(_ completion: @escaping (String?) -> Void) {
        guard let provider = provider else { return completion(nil) }

        lock.lock()
        if let token = heldLocked() {
            lock.unlock()
            return completion(token)
        }
        waiters.append(completion)
        let first = waiters.count == 1
        if first {
            fetchId += 1
            lastAskedAt = Date().timeIntervalSince1970
        }
        let id = fetchId
        lock.unlock()
        guard first else { return }

        let finish: (String?) -> Void = { [weak self] fetched in
            guard let self = self else { return }
            self.lock.lock()
            // Answered already (the provider called back twice, or after the timeout).
            guard id == self.fetchId, !self.waiters.isEmpty else {
                self.lock.unlock()
                return
            }
            if let fetched = fetched, !fetched.isEmpty {
                self.cachedToken = fetched
                self.cachedTokenExpiresAt = TokenClaims.expiry(fetched)
            } else if self.cachedTokenExpiresAt <= Date().timeIntervalSince1970 {
                // A token that still works is better than none; an expired one is not.
                self.cachedToken = nil
                self.cachedTokenExpiresAt = 0
            }
            let token = self.cachedToken
            let waiters = self.waiters
            self.waiters = []
            self.lock.unlock()
            waiters.forEach { $0(token) }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + providerTimeout) {
            finish(nil)
        }
        provider { result in
            if case .success(let token) = result {
                finish(token)
            } else {
                Log.debug("tokenProvider gave no token")
                finish(nil)
            }
        }
    }
}
