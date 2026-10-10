import Foundation

/// RiviumAbTesting - A/B Testing SDK for iOS
///
/// Usage:
/// ```swift
/// // Initialize
/// RiviumAbTesting.shared.initialize(config: RiviumAbTestingConfig(apiKey: "rv_live_xxx"))
///
/// // Get variant for experiment
/// let variant = RiviumAbTesting.shared.getVariant(experimentKey: "experiment-key")
///
/// // Track conversion
/// RiviumAbTesting.shared.trackConversion(experimentKey: "experiment-key", value: 99.99)
/// ```
///
/// No method here stops the app when the SDK is not initialized or no user is
/// signed in: getters return the default you pass and `track…` does nothing.
///
/// The user token decides what may be sent. Without one (no one is signed in
/// yet) the SDK is awaiting a user token: nothing that acts for a user goes to
/// the service, variants are the caller's defaults and events are kept. When a
/// token arrives the assignments the app asked for are fetched and the kept
/// events are sent.
public final class RiviumAbTesting {
    /// Shared singleton instance
    public static let shared = RiviumAbTesting()

    /// Where the SDK keeps its data and how it reaches the service.
    internal struct Environment {
        var defaults: UserDefaults = .standard
        var sessionConfiguration: URLSessionConfiguration = .default
        var queueFileURL: URL? = EventQueue.defaultFileURL
        var legacyQueueFileURL: URL? = EventQueue.legacyFileURL
        var observesNetwork = true
        var tokenProviderTimeout: TimeInterval = 15
    }

    private let environment: Environment

    private var config: RiviumAbTestingConfig?
    private var storage: Storage?
    private var apiClient: ApiClient?
    private var tokens: UserTokens?
    private var eventQueue: EventQueue?
    private let targetingEngine = TargetingEngine()
    private var networkObserver: NetworkObserver?
    private var flushTimer: DispatchSourceTimer?

    private var delegates = NSHashTable<AnyObject>.weakObjects()
    private var experiments: [Experiment] = []
    private var featureFlags: [FeatureFlag] = []
    private var isInitialized = false
    private var isLoading = false
    private var lastLoadFailed = false

    private let delegateLock = NSLock()
    private let experimentLock = NSLock()
    private let flagLock = NSLock()

    // The user and the user token; guarded by stateLock.
    private let stateLock = NSRecursiveLock()
    private var awaitingUserToken = false
    private var awaitingHandler: (() -> Void)?
    /// Experiments the app asked a variant for and the service has not answered yet.
    private var wanted: [String] = []
    private var assigning: [String: [(Assignment?) -> Void]] = [:]
    private var assignRetryAt: [String: TimeInterval] = [:]
    private var rateLimitedUntil: TimeInterval = 0
    private var rejectedToken: String?
    private var adoptedToken: String?

    /// Background work starts here, so no public call waits on the network
    /// or on the app's token provider.
    private let work = DispatchQueue(label: "co.rivium.abtesting.work")

    /// After a failed assignment the same experiment is not asked about again for this long.
    private static let assignRetryDelay: TimeInterval = 10
    private static let defaultRateLimitPause: TimeInterval = 60

    internal init(environment: Environment = Environment()) {
        self.environment = environment
    }

    // MARK: - Initialization

    /// Initialize RiviumAbTesting SDK
    ///
    /// If the first attempt could not reach the service (no network), the SDK
    /// works from what it has cached and loads again when the network
    /// returns; calling `initialize` again also tries again.
    ///
    /// - Parameters:
    ///   - config: SDK configuration
    ///   - delegate: Optional delegate for SDK events
    public func initialize(config: RiviumAbTestingConfig, delegate: RiviumAbTestingDelegate? = nil) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard self.config == nil else {
            // Already running: never a second queue or timer.
            if isInitialized {
                delegate?.riviumAbTestingDidInitialize()
            } else if let delegate = delegate {
                addDelegate(delegate)
            }
            // A load that reached nothing (no network) is tried again.
            if !isInitialized || lastLoadFailed { load() }
            return
        }

        Log.isEnabled = config.debug
        Log.debug("Initializing")

        let storage = Storage(defaults: environment.defaults)
        let apiClient = ApiClient(config: config, sessionConfiguration: environment.sessionConfiguration)
        self.config = config
        self.storage = storage
        self.apiClient = apiClient
        self.tokens = UserTokens(
            provider: config.tokenProvider,
            userToken: config.userToken,
            providerTimeout: environment.tokenProviderTimeout
        )
        self.eventQueue = EventQueue(
            flushInterval: config.flushInterval,
            fileURL: environment.queueFileURL,
            legacyFileURL: environment.legacyQueueFileURL,
            currentUserId: { storage.userId },
            send: { [weak self] userId, events, completion in
                guard let self = self else { return completion(nil) }
                self.asUser(userId, { token, done in
                    apiClient.trackEvents(events, token: token, completion: done)
                }, completion: completion)
            }
        )

        if let delegate = delegate {
            addDelegate(delegate)
        }

        // Generate or restore user ID
        if storage.userId == nil {
            storage.userId = UUID().uuidString
            storage.userIdGenerated = true
        }

        // Start event queue
        eventQueue?.start()
        startFlushTimer(interval: config.flushInterval)

        // Load cached experiments and feature flags
        experimentLock.lock()
        experiments = storage.getExperiments()
        experimentLock.unlock()
        flagLock.lock()
        featureFlags = storage.getFeatureFlags()
        flagLock.unlock()

        if environment.observesNetwork {
            let observer = NetworkObserver { [weak self] in self?.networkAvailable() }
            observer.start()
            networkObserver = observer
        }

        // Fetch fresh experiments and feature flags
        load()
    }

    /// Fetches experiments and flags, then finds out who the user is.
    private func load() {
        stateLock.lock()
        guard config != nil, !isLoading else {
            stateLock.unlock()
            return
        }
        isLoading = true
        stateLock.unlock()

        let group = DispatchGroup()
        var loadedExperiments = false
        var loadedFlags = false

        group.enter()
        loadExperiments { ok in
            loadedExperiments = ok
            group.leave()
        }

        group.enter()
        loadFeatureFlags { ok in
            loadedFlags = ok
            group.leave()
        }

        group.notify(queue: work) { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            self.isLoading = false
            // With nothing loaded the SDK works from its cache; the load is
            // tried again when the network returns.
            self.lastLoadFailed = !loadedExperiments && !loadedFlags
            let first = !self.isInitialized
            self.isInitialized = true
            self.stateLock.unlock()

            if first {
                self.notifyDelegates { $0.riviumAbTestingDidInitialize() }
            }
            // Who is the user? Without a token the SDK waits for one.
            self.resolveToken(force: true) { token in
                if token != nil { self.resume() }
            }
        }
    }

    private func startFlushTimer(interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: work)
        let seconds = max(interval, 1)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // While waiting for a user token the timer does nothing.
            if !self.isAwaitingUserToken { self.eventQueue?.flush() }
        }
        timer.resume()
        flushTimer = timer
    }

    private func networkAvailable() {
        Log.debug("Network available")
        eventQueue?.networkAvailable()
        stateLock.lock()
        assignRetryAt = [:]
        let reload = lastLoadFailed
        stateLock.unlock()

        if reload {
            load()
        } else {
            refreshExperiments()
            refreshFeatureFlags()
            work.async { [weak self] in
                guard let self = self, !self.isAwaitingUserToken else { return }
                self.resume()
            }
        }
    }

    // MARK: - User Management

    /// Set user ID for experiment assignment
    ///
    /// With a different id this is a user switch: the previous user's
    /// variants, attributes, token and pending events are cleared before
    /// anything is done for the new user.
    public func setUserId(_ userId: String) {
        guard let storage = storage, let tokens = tokens else { return notInitialized("setUserId") }
        stateLock.lock()
        let previous = storage.userId
        if previous == userId {
            storage.userIdGenerated = false
            stateLock.unlock()
            return
        }
        let leaving = previous.flatMap { takeLeave($0) }
        // A token for someone else is not this user's. The right one is fetched below.
        tokens.dropTokensNotFor(userId)
        // The attributes an app set before sign-in describe this same person;
        // a previous user's do not.
        switchUser(to: userId, keepAttributes: storage.userIdGenerated)
        stateLock.unlock()

        if let leaving = leaving { sendOff(leaving) }
        work.async { [weak self] in
            self?.resolveToken(force: true) { token in
                if token != nil { self?.resume() }
            }
        }
    }

    /// Sign-out: forgets the user, their variants, attributes, token and
    /// pending events. The SDK then waits for a user token again (see
    /// `isAwaitingUserToken`).
    public func clearUserId() {
        guard let storage = storage, let tokens = tokens else { return notInitialized("clearUserId") }
        stateLock.lock()
        let leaving = storage.userId.flatMap { takeLeave($0) }
        tokens.clear()
        tokens.markAsked()
        switchUser(to: UUID().uuidString, keepAttributes: false)
        storage.userIdGenerated = true
        stateLock.unlock()

        if let leaving = leaving { sendOff(leaving) }
        enterWaiting()
    }

    /// Get current user ID
    public func getUserId() -> String? {
        return storage?.userId
    }

    /// Set user attributes for targeting
    public func setUserAttributes(_ attributes: [String: Any]) {
        guard let storage = storage else { return notInitialized("setUserAttributes") }
        storage.userAttributes = attributes
        // Targeting is decided by the service from the attributes: ask again
        // for the experiments it kept this user out of.
        storage.clearOutsideAssignments()
    }

    // MARK: - User Token

    /// True while the SDK waits for a user token: assigning variants,
    /// tracking and flag evaluation need one and the app has not supplied one
    /// (no one is signed in yet). Nothing is sent for a user meanwhile:
    /// `getVariant` returns the default you pass and events are kept. The SDK
    /// carries on by itself once `setUserToken(_:)` is called, or after
    /// `refreshUserToken()` when a token provider is used.
    public var isAwaitingUserToken: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return awaitingUserToken
    }

    /// Called on the main thread once each time the SDK starts waiting for a user token.
    public var onAwaitingUserToken: (() -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return awaitingHandler
        }
        set {
            stateLock.lock()
            awaitingHandler = newValue
            stateLock.unlock()
        }
    }

    /// Hand the SDK a user token minted by your server, for apps that do not
    /// use a token provider. Call it after sign-in and whenever you refresh
    /// the token; pass nil after sign-out.
    ///
    /// If the SDK was waiting for a token it carries on now: the variants
    /// your app asked for are fetched and the kept events are sent. A token
    /// for another user is a user switch, as in `setUserId(_:)`.
    public func setUserToken(_ token: String?) {
        guard let storage = storage, let tokens = tokens else { return notInitialized("setUserToken") }
        guard let token = token, !token.isEmpty else {
            clearUserId()
            return
        }
        stateLock.lock()
        var leaving: Leaving?
        if let user = TokenClaims.subject(token), let previous = storage.userId, previous != user {
            leaving = takeLeave(previous)
        }
        tokens.set(token)
        rejectedToken = nil
        let wasAwaiting = awaitingUserToken
        stateLock.unlock()

        if let leaving = leaving { sendOff(leaving) }
        adopt(token)
        if !wasAwaiting {
            work.async { [weak self] in self?.resume() }
        }
    }

    /// For apps that use a token provider: call this when the user signs in
    /// or out. The SDK asks the provider again now and carries on as that
    /// user, or waits if the provider has no token.
    public func refreshUserToken() {
        guard let tokens = tokens else { return notInitialized("refreshUserToken") }
        tokens.forgetFetched()
        work.async { [weak self] in
            self?.resolveToken(force: true) { token in
                if token != nil { self?.resume() }
            }
        }
    }

    /// The token to act for the user with, or nil when there is none (the
    /// SDK then waits for one).
    ///
    /// While waiting, the provider is not asked on every call: only when
    /// `force` is set (the app said something changed) or some time has passed.
    private func resolveToken(force: Bool = false, completion: @escaping (String?) -> Void) {
        guard let tokens = tokens else { return completion(nil) }
        let finish: (String?) -> Void = { [weak self] fetched in
            guard let self = self else { return completion(nil) }
            self.stateLock.lock()
            // A token the service refused is as good as none until the app has another.
            let token = fetched == self.rejectedToken ? nil : fetched
            self.stateLock.unlock()
            guard let usable = token else {
                self.enterWaiting()
                return completion(nil)
            }
            self.adopt(usable)
            completion(usable)
        }

        if let token = tokens.held() {
            finish(token)
        } else if tokens.hasProvider {
            if !force && isAwaitingUserToken && !tokens.mayAskAgain { return completion(nil) }
            tokens.fetch(finish)
        } else {
            finish(nil)
        }
    }

    /// A token is there: its user becomes the SDK's user, and the wait is over.
    private func adopt(_ token: String) {
        stateLock.lock()
        if adoptedToken != token, let storage = storage {
            let user = TokenClaims.subject(token)
            if let user = user, user != storage.userId {
                // The attributes an app set before sign-in describe this same
                // person; a previous user's do not.
                switchUser(to: user, keepAttributes: storage.userIdGenerated)
            }
            if user != nil { storage.userIdGenerated = false }
            adoptedToken = token
        }
        let resumed = awaitingUserToken
        awaitingUserToken = false
        stateLock.unlock()

        if resumed {
            Log.debug("User token available")
            work.async { [weak self] in self?.resume() }
        }
    }

    private func enterWaiting() {
        stateLock.lock()
        let entered = !awaitingUserToken
        awaitingUserToken = true
        stateLock.unlock()
        guard entered else { return }

        Log.debug("Awaiting a user token")
        DispatchQueue.main.async { [weak self] in
            self?.onAwaitingUserToken?()
        }
    }

    /// Everything kept for the previous user goes before anything is done
    /// for the next one: assignments, attributes and events. Call with the
    /// lock held.
    private func switchUser(to userId: String, keepAttributes: Bool) {
        adoptedToken = nil
        storage?.userId = userId
        storage?.userIdGenerated = false
        storage?.clearAssignments()
        if !keepAttributes { storage?.userAttributes = nil }
        eventQueue?.retainUser(userId)
        assignRetryAt = [:]
        Log.debug("User changed")
    }

    private struct Leaving {
        let events: [TrackEvent]
        let token: String
    }

    /// Takes the leaving user's finished events and their token, while both
    /// are still there. Nil when there is nothing to send or no token of
    /// theirs to send it under. Call with the lock held.
    private func takeLeave(_ previous: String) -> Leaving? {
        let events = eventQueue?.detach(userId: previous) ?? []
        guard let token = tokens?.peek(), !events.isEmpty, token != rejectedToken else { return nil }
        if let tokenUser = TokenClaims.subject(token), tokenUser != previous { return nil }
        return Leaving(events: events, token: token)
    }

    /// Best effort: one attempt under the leaving user's own token. What fails is dropped.
    private func sendOff(_ leaving: Leaving) {
        guard let apiClient = apiClient else { return }
        var rest = leaving.events[...]
        func next() {
            guard !rest.isEmpty else { return }
            let chunk = Array(rest.prefix(ApiClient.maxEventsPerRequest))
            rest = rest.dropFirst(chunk.count)
            apiClient.trackEvents(chunk, token: leaving.token) { result in
                if case .success = result { next() }
            }
        }
        work.async { next() }
    }

    /// Runs a call that acts for `userId` with their token. Nil when there
    /// is no token for them: the caller keeps its work and waits.
    ///
    /// One refresh and one retry when the service says the token expired. A
    /// token the service refuses is reported once and not sent again.
    private func asUser<T>(
        _ userId: String,
        _ call: @escaping (_ token: String, _ done: @escaping (Result<T, ApiFailure>) -> Void) -> Void,
        completion: @escaping (Result<T, ApiFailure>?) -> Void
    ) {
        stateLock.lock()
        let wait = rateLimitedUntil - Date().timeIntervalSince1970
        stateLock.unlock()
        if wait > 0 {
            return completion(.failure(ApiFailure(status: 429, message: "Rate limited", retryAfter: wait)))
        }

        resolveToken { [weak self] token in
            guard let self = self, let token = token, self.storage?.userId == userId else { return completion(nil) }
            call(token) { result in
                guard case .failure(let failure) = result, failure.status == 401, failure.code == "token_expired" else {
                    self.settle(result, token: token)
                    return completion(result)
                }
                self.tokens?.invalidate(token)
                self.resolveToken(force: true) { fresh in
                    guard let fresh = fresh, self.storage?.userId == userId else { return completion(nil) }
                    guard fresh != token else {
                        self.settle(result, token: token)
                        return completion(result)
                    }
                    call(fresh) { retried in
                        self.settle(retried, token: fresh)
                        completion(retried)
                    }
                }
            }
        }
    }

    /// What a refused call means for the token and for the calls after it.
    private func settle<T>(_ result: Result<T, ApiFailure>, token: String) {
        guard case .failure(let failure) = result else { return }
        if failure.status == 429 {
            stateLock.lock()
            rateLimitedUntil = Date().timeIntervalSince1970 + (failure.retryAfter ?? Self.defaultRateLimitPause)
            stateLock.unlock()
        } else if failure.status == 401, failure.code == "token_required" {
            tokens?.invalidate(token)
            enterWaiting()
        } else if failure.status == 401 {
            // The service refused this token: say so once, then wait for another one.
            stateLock.lock()
            let first = rejectedToken != token
            rejectedToken = token
            stateLock.unlock()
            tokens?.invalidate(token)
            if first {
                Log.debug("User token rejected: \(failure.code ?? "401")")
                let error = failure.publicError
                notifyDelegates { $0.riviumAbTesting(didReceiveError: error) }
            }
            enterWaiting()
        }
    }

    /// A token just arrived: fetch the assignments the app asked for, then
    /// send the kept events.
    private func resume() {
        guard let storage = storage, let queue = eventQueue, let userId = storage.userId else { return }
        stateLock.lock()
        var keys = wanted
        stateLock.unlock()
        let known = getExperiments()
        for experimentId in queue.parkedExperimentIds(userId: userId) {
            if let key = known.first(where: { $0.id == experimentId })?.key {
                if !keys.contains(key) { keys.append(key) }
            } else {
                // An experiment that is gone can never take these events.
                queue.resolve(userId: userId, experimentId: experimentId, variantId: nil)
            }
        }

        var rest = keys[...]
        func next() {
            if isAwaitingUserToken { return }
            guard let key = rest.popFirst() else { return queue.flush() }
            if storage.getAssignment(forExperimentKey: key) != nil { return next() }
            fetchAssignment(key, ignoreRetryDelay: true) { _ in next() }
        }
        next()
    }

    // MARK: - Experiment API

    /// The experiment, if a variant of it can be asked for; nil → the caller's default.
    private func assignable(_ experimentKey: String) -> Experiment? {
        experimentLock.lock()
        let experiment = experiments.first { $0.key == experimentKey }
        experimentLock.unlock()

        guard let exp = experiment, exp.status == .running else { return nil }
        if let rules = exp.targetingRules,
           !targetingEngine.evaluate(rules: rules, userAttributes: storage?.userAttributes) {
            return nil
        }
        return exp
    }

    private func want(_ experimentKey: String) {
        stateLock.lock()
        if !wanted.contains(experimentKey) { wanted.append(experimentKey) }
        stateLock.unlock()
    }

    private func unwant(_ experimentKey: String) {
        stateLock.lock()
        wanted.removeAll { $0 == experimentKey }
        stateLock.unlock()
    }

    /// Get variant for an experiment
    ///
    /// Never blocks: returns the variant the service assigned earlier, or
    /// `defaultVariant` while the answer is fetched in the background (then
    /// the delegate's `didAssignVariant` is called). Use
    /// `getVariant(experimentKey:defaultVariant:completion:)` to wait for
    /// the answer.
    ///
    /// - Parameters:
    ///   - experimentKey: The experiment key
    ///   - defaultVariant: Default variant to return if experiment not found
    /// - Returns: The assigned variant key, or defaultVariant if not found
    public func getVariant(experimentKey: String, defaultVariant: String = "control") -> String {
        guard let storage = storage else {
            notInitialized("getVariant")
            return defaultVariant
        }

        // Check cached assignment
        if let assignment = storage.getAssignment(forExperimentKey: experimentKey) {
            return assignment.variantKey
        }

        guard assignable(experimentKey) != nil else {
            return defaultVariant
        }

        want(experimentKey)
        if isAwaitingUserToken {
            askProviderAgain()
        } else {
            work.async { [weak self] in
                self?.fetchAssignment(experimentKey) { _ in }
            }
        }
        return defaultVariant
    }

    /// Get variant asynchronously: waits for the service's answer.
    /// `completion` is called on the main thread, with `defaultVariant` when
    /// there is no answer (no user token yet, no network, not in the
    /// experiment list).
    public func getVariant(
        experimentKey: String,
        defaultVariant: String = "control",
        completion: @escaping (String) -> Void
    ) {
        work.async { [weak self] in
            let finish: (String) -> Void = { variant in
                DispatchQueue.main.async { completion(variant) }
            }
            guard let self = self, let storage = self.storage else { return finish(defaultVariant) }
            if let assignment = storage.getAssignment(forExperimentKey: experimentKey) {
                return finish(assignment.variantKey)
            }
            guard self.assignable(experimentKey) != nil else { return finish(defaultVariant) }
            self.want(experimentKey)
            self.fetchAssignment(experimentKey, ignoreRetryDelay: true) { assignment in
                finish(assignment?.variantKey ?? defaultVariant)
            }
        }
    }

    /// Get variant configuration
    public func getVariantConfig(experimentKey: String) -> [String: Any]? {
        return storage?.getAssignment(forExperimentKey: experimentKey)?.config?.mapValues { $0.value }
    }

    /// While waiting, an app that never calls `refreshUserToken()` still
    /// gets its provider asked now and then.
    private func askProviderAgain() {
        guard let tokens = tokens, tokens.hasProvider, tokens.mayAskAgain else { return }
        work.async { [weak self] in
            self?.resolveToken { _ in }
        }
    }

    /// One request per experiment at a time, however many callers ask.
    private func fetchAssignment(
        _ experimentKey: String,
        ignoreRetryDelay: Bool = false,
        completion: @escaping (Assignment?) -> Void
    ) {
        stateLock.lock()
        if assigning[experimentKey] != nil {
            assigning[experimentKey]?.append(completion)
            stateLock.unlock()
            return
        }
        assigning[experimentKey] = [completion]
        stateLock.unlock()

        requestAssignment(experimentKey, ignoreRetryDelay: ignoreRetryDelay) { [weak self] assignment in
            guard let self = self else { return completion(assignment) }
            self.stateLock.lock()
            let waiting = self.assigning.removeValue(forKey: experimentKey) ?? []
            self.stateLock.unlock()
            waiting.forEach { $0(assignment) }
        }
    }

    private func requestAssignment(
        _ experimentKey: String,
        ignoreRetryDelay: Bool,
        completion: @escaping (Assignment?) -> Void
    ) {
        guard let storage = storage, let apiClient = apiClient, let userId = storage.userId else {
            return completion(nil)
        }
        if let assignment = storage.getAssignment(forExperimentKey: experimentKey) {
            return completion(assignment)
        }
        stateLock.lock()
        let retryAt = assignRetryAt[experimentKey] ?? 0
        stateLock.unlock()
        if !ignoreRetryDelay && Date().timeIntervalSince1970 < retryAt { return completion(nil) }

        let userAttributes = storage.userAttributes
        asUser(userId, { token, done in
            apiClient.getAssignment(
                experimentKey: experimentKey,
                userId: userId,
                userAttributes: userAttributes,
                token: token,
                completion: done
            )
        }, completion: { [weak self] (result: Result<Assignment, ApiFailure>?) in
            guard let self = self, let result = result else { return completion(nil) }
            switch result {
            case .success(let assignment):
                self.stateLock.lock()
                // The user changed while the service answered: not theirs.
                guard storage.userId == userId else {
                    self.stateLock.unlock()
                    return completion(nil)
                }
                storage.saveAssignment(assignment, forExperimentKey: experimentKey)
                self.wanted.removeAll { $0 == experimentKey }
                self.assignRetryAt[experimentKey] = nil
                self.stateLock.unlock()

                // Events recorded before the answer can go now - unless the
                // user is only shown the control and does not take part.
                self.eventQueue?.resolve(
                    userId: userId,
                    experimentId: assignment.experimentId,
                    variantId: assignment.inExperiment == false ? nil : assignment.variantId
                )
                let configDict = assignment.config?.mapValues { $0.value }
                self.notifyDelegates {
                    $0.riviumAbTesting(didAssignVariant: assignment.variantKey,
                               forExperiment: experimentKey,
                               config: configDict)
                }
                if let queue = self.eventQueue, queue.pendingCount > 0, !queue.isPaused {
                    queue.flush()
                }
                completion(assignment)

            case .failure(let failure):
                Log.debug("No assignment for \(experimentKey): \(failure.message)")
                self.stateLock.lock()
                self.assignRetryAt[experimentKey] = Date().timeIntervalSince1970 + Self.assignRetryDelay
                self.stateLock.unlock()
                if let status = failure.status, (400..<500).contains(status), status != 401, status != 429 {
                    // The experiment is gone or not running: nothing to wait for.
                    self.unwant(experimentKey)
                    if let experiment = self.getExperiments().first(where: { $0.key == experimentKey }) {
                        self.eventQueue?.resolve(userId: userId, experimentId: experiment.id, variantId: nil)
                    }
                }
                completion(nil)
            }
        })
    }

    // MARK: - Event Tracking

    /// Track a view event
    public func trackView(experimentKey: String) {
        trackEvent(experimentKey: experimentKey, eventType: .view)
    }

    /// Track a click event
    public func trackClick(experimentKey: String) {
        trackEvent(experimentKey: experimentKey, eventType: .click)
    }

    /// Track a conversion event
    public func trackConversion(experimentKey: String, value: Double? = nil) {
        trackEvent(experimentKey: experimentKey, eventType: .conversion, eventValue: value)
    }

    /// Track a custom event
    public func trackCustomEvent(
        experimentKey: String,
        eventName: String,
        properties: [String: Any]? = nil
    ) {
        trackEvent(experimentKey: experimentKey, eventType: .custom, eventName: eventName, properties: properties)
    }

    /// Track a generic event with any type
    public func track(
        experimentKey: String,
        eventType: EventType,
        eventName: String? = nil,
        eventValue: Double? = nil,
        properties: [String: Any]? = nil
    ) {
        trackEvent(experimentKey: experimentKey, eventType: eventType, eventName: eventName, eventValue: eventValue, properties: properties)
    }

    // MARK: - Engagement Events

    /// Track a scroll event
    public func trackScroll(experimentKey: String, depth: Double? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let depth = depth { props["depth"] = depth }
        trackEvent(experimentKey: experimentKey, eventType: .scroll, properties: props)
    }

    /// Track a form submission event
    public func trackFormSubmit(experimentKey: String, formName: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let formName = formName { props["formName"] = formName }
        trackEvent(experimentKey: experimentKey, eventType: .formSubmit, properties: props)
    }

    /// Track a search event
    public func trackSearch(experimentKey: String, query: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let query = query { props["query"] = query }
        trackEvent(experimentKey: experimentKey, eventType: .search, properties: props)
    }

    /// Track a share event
    public func trackShare(experimentKey: String, method: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let method = method { props["method"] = method }
        trackEvent(experimentKey: experimentKey, eventType: .share, properties: props)
    }

    // MARK: - E-Commerce Events

    /// Track add to cart event
    public func trackAddToCart(experimentKey: String, value: Double? = nil, productId: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let productId = productId { props["productId"] = productId }
        trackEvent(experimentKey: experimentKey, eventType: .addToCart, eventValue: value, properties: props)
    }

    /// Track remove from cart event
    public func trackRemoveFromCart(experimentKey: String, value: Double? = nil, productId: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let productId = productId { props["productId"] = productId }
        trackEvent(experimentKey: experimentKey, eventType: .removeFromCart, eventValue: value, properties: props)
    }

    /// Track begin checkout event
    public func trackBeginCheckout(experimentKey: String, value: Double? = nil, properties: [String: Any]? = nil) {
        trackEvent(experimentKey: experimentKey, eventType: .beginCheckout, eventValue: value, properties: properties)
    }

    /// Track purchase event
    public func trackPurchase(experimentKey: String, value: Double, transactionId: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let transactionId = transactionId { props["transactionId"] = transactionId }
        trackEvent(experimentKey: experimentKey, eventType: .purchase, eventValue: value, properties: props)
    }

    // MARK: - Media Events

    /// Track video start event
    public func trackVideoStart(experimentKey: String, videoId: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let videoId = videoId { props["videoId"] = videoId }
        trackEvent(experimentKey: experimentKey, eventType: .videoStart, properties: props)
    }

    /// Track video complete event
    public func trackVideoComplete(experimentKey: String, videoId: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let videoId = videoId { props["videoId"] = videoId }
        trackEvent(experimentKey: experimentKey, eventType: .videoComplete, properties: props)
    }

    // MARK: - Auth Events

    /// Track sign up event
    public func trackSignUp(experimentKey: String, method: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let method = method { props["method"] = method }
        trackEvent(experimentKey: experimentKey, eventType: .signUp, properties: props)
    }

    /// Track login event
    public func trackLogin(experimentKey: String, method: String? = nil, properties: [String: Any]? = nil) {
        var props = properties ?? [:]
        if let method = method { props["method"] = method }
        trackEvent(experimentKey: experimentKey, eventType: .login, properties: props)
    }

    /// Track logout event
    public func trackLogout(experimentKey: String, properties: [String: Any]? = nil) {
        trackEvent(experimentKey: experimentKey, eventType: .logout, properties: properties)
    }

    // MARK: - Experiment Management

    /// Refresh experiments from server
    public func refreshExperiments(completion: (() -> Void)? = nil) {
        loadExperiments { _ in completion?() }
    }

    private func loadExperiments(completion: @escaping (Bool) -> Void) {
        guard let apiClient = apiClient else { return completion(false) }
        apiClient.fetchExperiments { [weak self] result in
            switch result {
            case .success(let fetchedExperiments):
                self?.experimentLock.lock()
                self?.experiments = fetchedExperiments
                self?.experimentLock.unlock()

                self?.storage?.saveExperiments(fetchedExperiments)
                self?.notifyDelegates { $0.riviumAbTesting(didRefreshExperiments: fetchedExperiments) }
                completion(true)

            case .failure(let failure):
                let error = failure.publicError
                self?.notifyDelegates { $0.riviumAbTesting(didReceiveError: error) }
                completion(false)
            }
        }
    }

    /// Get all experiments
    public func getExperiments() -> [Experiment] {
        experimentLock.lock()
        let result = experiments
        experimentLock.unlock()
        return result
    }

    // MARK: - Feature Flags

    /// Check if a feature flag is enabled
    ///
    /// This evaluates the feature flag from the RiviumAbTesting dashboard.
    /// The flag is evaluated based on:
    /// - Whether the flag is globally enabled
    /// - Rollout percentage (for gradual rollouts)
    /// - Targeting rules (if configured)
    ///
    /// - Parameters:
    ///   - flagKey: The feature flag key
    ///   - defaultValue: Default value if flag not found (default: false)
    /// - Returns: true if the flag is enabled for this user
    public func isFeatureEnabled(_ flagKey: String, defaultValue: Bool = false) -> Bool {
        // Find the flag
        flagLock.lock()
        let flag = featureFlags.first { $0.key == flagKey }
        flagLock.unlock()

        guard let flag = flag else {
            return defaultValue
        }

        // If flag is globally disabled, return false
        guard flag.enabled else {
            return false
        }

        // Check rollout percentage using user ID hash
        guard let userId = storage?.userId else {
            return defaultValue
        }

        if flag.rolloutPercentage < 100 {
            let combined = userId + flagKey
            let hash = RolloutHash.bucket(combined)
            if hash >= flag.rolloutPercentage {
                return false
            }
        }

        // Check targeting rules if present
        if let rules = flag.targetingRules, !rules.isEmpty {
            let userAttributes = storage?.userAttributes
            if !targetingEngine.evaluate(rules: rules, userAttributes: userAttributes) {
                return false
            }
        }

        return true
    }

    /// Check if a feature flag is enabled (async version with server evaluation)
    ///
    /// This makes a server call to evaluate the flag, which ensures
    /// the most up-to-date flag configuration is used. Without a user token
    /// (or a network) the local answer is given.
    ///
    /// - Parameters:
    ///   - flagKey: The feature flag key
    ///   - defaultValue: Default value if evaluation fails
    ///   - completion: Callback with the result
    public func isFeatureEnabled(
        _ flagKey: String,
        defaultValue: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        guard let storage = storage, let apiClient = apiClient, let userId = storage.userId else {
            completion(defaultValue)
            return
        }

        let userAttributes = storage.userAttributes
        work.async { [weak self] in
            guard let self = self else { return }
            self.asUser(userId, { token, done in
                apiClient.evaluateFlag(
                    flagKey: flagKey,
                    userId: userId,
                    userAttributes: userAttributes,
                    token: token,
                    completion: done
                )
            }, completion: { (result: Result<FlagEvaluationResult, ApiFailure>?) in
                let enabled: Bool
                if case .some(.success(let evaluation)) = result {
                    enabled = evaluation.enabled
                } else {
                    enabled = self.isFeatureEnabled(flagKey, defaultValue: defaultValue)
                }
                DispatchQueue.main.async {
                    completion(enabled)
                }
            })
        }
    }

    /// Get the value of a feature flag
    ///
    /// Feature flags can have associated values (strings, numbers, JSON objects).
    /// This returns the value for the flag if enabled, or the default value otherwise.
    ///
    /// - Parameters:
    ///   - flagKey: The feature flag key
    ///   - defaultValue: Default value if flag not found or disabled
    /// - Returns: The flag value or default
    public func getFeatureValue(_ flagKey: String, defaultValue: Any? = nil) -> Any? {
        flagLock.lock()
        let flag = featureFlags.first { $0.key == flagKey }
        flagLock.unlock()

        guard let flag = flag, isFeatureEnabled(flagKey) else {
            return defaultValue
        }

        return flag.defaultValue?.value ?? defaultValue
    }

    /// Get all feature flags
    public func getFeatureFlags() -> [FeatureFlag] {
        flagLock.lock()
        let result = featureFlags
        flagLock.unlock()
        return result
    }

    /// Refresh feature flags from server
    public func refreshFeatureFlags(completion: (() -> Void)? = nil) {
        loadFeatureFlags { _ in completion?() }
    }

    private func loadFeatureFlags(completion: @escaping (Bool) -> Void) {
        guard let apiClient = apiClient else { return completion(false) }
        apiClient.fetchFeatureFlags { [weak self] result in
            switch result {
            case .success(let fetchedFlags):
                self?.flagLock.lock()
                self?.featureFlags = fetchedFlags
                self?.flagLock.unlock()

                self?.storage?.saveFeatureFlags(fetchedFlags)
                self?.notifyDelegates { $0.riviumAbTesting(didRefreshFeatureFlags: fetchedFlags) }
                completion(true)

            case .failure(let failure):
                let error = failure.publicError
                self?.notifyDelegates { $0.riviumAbTesting(didReceiveError: error) }
                completion(false)
            }
        }
    }

    // MARK: - Delegate Management

    /// Add delegate for SDK events
    public func addDelegate(_ delegate: RiviumAbTestingDelegate) {
        delegateLock.lock()
        delegates.add(delegate)
        delegateLock.unlock()
    }

    /// Remove delegate
    public func removeDelegate(_ delegate: RiviumAbTestingDelegate) {
        delegateLock.lock()
        delegates.remove(delegate)
        delegateLock.unlock()
    }

    // MARK: - Lifecycle

    /// Flush pending events
    public func flush() {
        if isAwaitingUserToken {
            askProviderAgain()
            return
        }
        work.async { [weak self] in
            self?.eventQueue?.flush()
        }
    }

    /// Reset SDK state (for testing)
    public func reset() {
        stateLock.lock()
        flushTimer?.cancel()
        flushTimer = nil
        networkObserver?.stop()
        networkObserver = nil
        tokens?.clear()
        eventQueue?.clear()
        storage?.clear()
        config = nil
        storage = nil
        apiClient = nil
        tokens = nil
        eventQueue = nil
        isInitialized = false
        isLoading = false
        lastLoadFailed = false
        awaitingUserToken = false
        wanted = []
        assigning = [:]
        assignRetryAt = [:]
        rateLimitedUntil = 0
        rejectedToken = nil
        adoptedToken = nil
        stateLock.unlock()

        experimentLock.lock()
        experiments = []
        experimentLock.unlock()
        flagLock.lock()
        featureFlags = []
        flagLock.unlock()
    }

    // MARK: - Private Methods

    private func trackEvent(
        experimentKey: String,
        eventType: EventType,
        eventName: String? = nil,
        eventValue: Double? = nil,
        properties: [String: Any]? = nil
    ) {
        guard let storage = storage, let queue = eventQueue, let config = config else {
            return notInitialized("track")
        }
        guard let userId = storage.userId else { return }

        let experimentId: String
        let variantId: String
        if let assignment = storage.getAssignment(forExperimentKey: experimentKey) {
            if assignment.inExperiment == false {
                Log.debug("User is not in experiment \(experimentKey) - event not recorded")
                return
            }
            experimentId = assignment.experimentId
            variantId = assignment.variantId
        } else {
            // No answer from the service yet (no user token, or the request
            // is on its way): the event is kept until the variant is known.
            stateLock.lock()
            let asked = wanted.contains(experimentKey)
            stateLock.unlock()
            guard asked, let experiment = getExperiments().first(where: { $0.key == experimentKey }) else {
                Log.debug("No assignment found for experiment: \(experimentKey). Call getVariant() first.")
                return
            }
            experimentId = experiment.id
            variantId = ""
        }

        let event = TrackEvent(
            experimentId: experimentId,
            variantId: variantId,
            userId: userId,
            eventType: eventType,
            eventName: eventName,
            eventValue: eventValue,
            properties: properties
        )

        let count = queue.enqueue(event)
        if isAwaitingUserToken {
            askProviderAgain()
        } else if count >= config.maxQueueSize && !queue.isPaused {
            work.async { queue.flush() }
        }
    }

    private func notInitialized(_ call: String) {
        Log.debug("\(call) ignored: RiviumAbTesting.shared.initialize() has not been called")
    }

    /// Delegates are called on the main thread.
    private func notifyDelegates(_ action: @escaping (RiviumAbTestingDelegate) -> Void) {
        delegateLock.lock()
        let allDelegates = delegates.allObjects.compactMap { $0 as? RiviumAbTestingDelegate }
        delegateLock.unlock()

        DispatchQueue.main.async {
            allDelegates.forEach(action)
        }
    }

    // MARK: - Test support

    internal var pendingEventCount: Int {
        return eventQueue?.pendingCount ?? 0
    }

    internal func waitForDisk() {
        eventQueue?.waitForDisk()
    }
}
