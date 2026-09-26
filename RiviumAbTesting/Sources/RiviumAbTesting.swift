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
public final class RiviumAbTesting {
    /// Shared singleton instance
    public static let shared = RiviumAbTesting()

    private var config: RiviumAbTestingConfig?
    private var storage: Storage?
    private var apiClient: ApiClient?
    private var eventQueue: EventQueue?
    private var targetingEngine: TargetingEngine?

    private var delegates = NSHashTable<AnyObject>.weakObjects()
    private var experiments: [Experiment] = []
    private var featureFlags: [FeatureFlag] = []
    private var isInitialized = false

    private let delegateLock = NSLock()
    private let experimentLock = NSLock()
    private let flagLock = NSLock()

    private init() {}

    // MARK: - Initialization

    /// Initialize RiviumAbTesting SDK
    ///
    /// - Parameters:
    ///   - config: SDK configuration
    ///   - delegate: Optional delegate for SDK events
    public func initialize(config: RiviumAbTestingConfig, delegate: RiviumAbTestingDelegate? = nil) {
        guard !isInitialized else {
            delegate?.riviumAbTestingDidInitialize()
            return
        }

        self.config = config
        self.storage = Storage()
        self.apiClient = ApiClient(config: config)
        let storage = self.storage
        self.eventQueue = EventQueue(
            apiClient: apiClient!,
            flushInterval: config.flushInterval,
            maxQueueSize: config.maxQueueSize,
            currentUserId: { storage?.userId }
        )
        self.targetingEngine = TargetingEngine()

        if let delegate = delegate {
            addDelegate(delegate)
        }

        // Generate or restore user ID
        if storage?.userId == nil {
            storage?.userId = UUID().uuidString
        }

        // Start event queue
        eventQueue?.start()

        // Load cached experiments and feature flags
        experiments = storage?.getExperiments() ?? []
        featureFlags = storage?.getFeatureFlags() ?? []

        // Fetch fresh experiments and feature flags
        let group = DispatchGroup()

        group.enter()
        refreshExperiments { group.leave() }

        group.enter()
        refreshFeatureFlags { group.leave() }

        group.notify(queue: .main) { [weak self] in
            self?.isInitialized = true
            self?.notifyDelegates { $0.riviumAbTestingDidInitialize() }
        }
    }

    // MARK: - User Management

    /// Set user ID for experiment assignment
    ///
    /// Call it again on login and logout. When the user changes, the last
    /// user's pending events are sent under their own token, then their token
    /// is dropped.
    public func setUserId(_ userId: String) {
        ensureInitialized()
        if let previous = storage?.userId, previous != userId {
            let oldToken = apiClient?.peekToken()
            apiClient?.clearToken()
            if let theirs = eventQueue?.detach(userId: previous) {
                eventQueue?.sendDetached(theirs, token: oldToken)
            }
        }
        storage?.userId = userId
        storage?.clearAssignments() // Clear cached assignments when user changes
    }

    /// Get current user ID
    public func getUserId() -> String? {
        return storage?.userId
    }

    /// Set user attributes for targeting
    public func setUserAttributes(_ attributes: [String: Any]) {
        ensureInitialized()
        storage?.userAttributes = attributes
    }

    // MARK: - Experiment API

    /// Get variant for an experiment
    ///
    /// - Parameters:
    ///   - experimentKey: The experiment key
    ///   - defaultVariant: Default variant to return if experiment not found
    /// - Returns: The assigned variant key, or defaultVariant if not found
    public func getVariant(experimentKey: String, defaultVariant: String = "control") -> String {
        ensureInitialized()

        // Check cached assignment
        if let assignment = storage?.getAssignment(forExperimentKey: experimentKey) {
            return assignment.variantKey
        }

        // Find experiment
        experimentLock.lock()
        let experiment = experiments.first { $0.key == experimentKey }
        experimentLock.unlock()

        guard let exp = experiment else {
            return defaultVariant
        }

        // Check if experiment is running
        guard exp.status == .running else {
            return defaultVariant
        }

        // Check targeting rules
        let userAttributes = storage?.userAttributes
        if let rules = exp.targetingRules,
           !targetingEngine!.evaluate(rules: rules, userAttributes: userAttributes) {
            return defaultVariant
        }

        // Get assignment from server
        guard let userId = storage?.userId else {
            return defaultVariant
        }

        var result = defaultVariant
        let semaphore = DispatchSemaphore(value: 0)

        apiClient?.getAssignment(
            experimentKey: experimentKey,
            userId: userId,
            userAttributes: userAttributes
        ) { [weak self] assignmentResult in
            switch assignmentResult {
            case .success(let assignment):
                self?.storage?.saveAssignment(assignment, forExperimentKey: experimentKey)
                result = assignment.variantKey

                let configDict = assignment.config?.mapValues { $0.value }
                self?.notifyDelegates {
                    $0.riviumAbTesting(didAssignVariant: assignment.variantKey,
                               forExperiment: experimentKey,
                               config: configDict)
                }
            case .failure:
                break
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    /// Get variant asynchronously
    public func getVariant(
        experimentKey: String,
        defaultVariant: String = "control",
        completion: @escaping (String) -> Void
    ) {
        DispatchQueue.global().async { [weak self] in
            let variant = self?.getVariant(experimentKey: experimentKey, defaultVariant: defaultVariant) ?? defaultVariant
            DispatchQueue.main.async {
                completion(variant)
            }
        }
    }

    /// Get variant configuration
    public func getVariantConfig(experimentKey: String) -> [String: Any]? {
        ensureInitialized()
        return storage?.getAssignment(forExperimentKey: experimentKey)?.config?.mapValues { $0.value }
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
        apiClient?.fetchExperiments { [weak self] result in
            switch result {
            case .success(let fetchedExperiments):
                self?.experimentLock.lock()
                self?.experiments = fetchedExperiments
                self?.experimentLock.unlock()

                self?.storage?.saveExperiments(fetchedExperiments)
                self?.notifyDelegates { $0.riviumAbTesting(didRefreshExperiments: fetchedExperiments) }

            case .failure(let error):
                self?.notifyDelegates { $0.riviumAbTesting(didReceiveError: error) }
            }
            completion?()
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
        ensureInitialized()

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
            if !targetingEngine!.evaluate(rules: rules, userAttributes: userAttributes) {
                return false
            }
        }

        return true
    }

    /// Check if a feature flag is enabled (async version with server evaluation)
    ///
    /// This makes a server call to evaluate the flag, which ensures
    /// the most up-to-date flag configuration is used.
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
        guard let userId = storage?.userId else {
            completion(defaultValue)
            return
        }

        apiClient?.evaluateFlag(
            flagKey: flagKey,
            userId: userId,
            userAttributes: storage?.userAttributes
        ) { [weak self] result in
            switch result {
            case .success(let evaluation):
                DispatchQueue.main.async {
                    completion(evaluation.enabled)
                }
            case .failure:
                DispatchQueue.main.async {
                    completion(self?.isFeatureEnabled(flagKey, defaultValue: defaultValue) ?? defaultValue)
                }
            }
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
        ensureInitialized()

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
        apiClient?.fetchFeatureFlags { [weak self] result in
            switch result {
            case .success(let fetchedFlags):
                self?.flagLock.lock()
                self?.featureFlags = fetchedFlags
                self?.flagLock.unlock()

                self?.storage?.saveFeatureFlags(fetchedFlags)
                self?.notifyDelegates { $0.riviumAbTesting(didRefreshFeatureFlags: fetchedFlags) }

            case .failure(let error):
                self?.notifyDelegates { $0.riviumAbTesting(didReceiveError: error) }
            }
            completion?()
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
        eventQueue?.flush()
    }

    /// Reset SDK state (for testing)
    public func reset() {
        apiClient?.clearToken()
        storage?.clear()
        experimentLock.lock()
        experiments = []
        experimentLock.unlock()
        flagLock.lock()
        featureFlags = []
        flagLock.unlock()
        isInitialized = false
    }

    // MARK: - Private Methods

    private func trackEvent(
        experimentKey: String,
        eventType: EventType,
        eventName: String? = nil,
        eventValue: Double? = nil,
        properties: [String: Any]? = nil
    ) {
        ensureInitialized()

        guard let assignment = storage?.getAssignment(forExperimentKey: experimentKey),
              let userId = storage?.userId else {
            return
        }

        let event = TrackEvent(
            experimentId: assignment.experimentId,
            variantId: assignment.variantId,
            userId: userId,
            eventType: eventType,
            eventName: eventName,
            eventValue: eventValue,
            properties: properties
        )

        eventQueue?.enqueue(event)
    }

    private func ensureInitialized() {
        guard isInitialized || config != nil else {
            fatalError("RiviumAbTesting SDK not initialized. Call RiviumAbTesting.shared.initialize() first.")
        }
    }

    private func notifyDelegates(_ action: @escaping (RiviumAbTestingDelegate) -> Void) {
        delegateLock.lock()
        let allDelegates = delegates.allObjects.compactMap { $0 as? RiviumAbTestingDelegate }
        delegateLock.unlock()

        DispatchQueue.main.async {
            allDelegates.forEach(action)
        }
    }
}
