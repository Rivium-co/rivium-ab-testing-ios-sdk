import Foundation

/// Delegate protocol for RiviumAbTesting SDK events
public protocol RiviumAbTestingDelegate: AnyObject {
    /// Called when SDK is initialized successfully
    func riviumAbTestingDidInitialize()

    /// Called when an error occurs
    func riviumAbTesting(didReceiveError error: RiviumAbTestingError)

    /// Called when a user is assigned to an experiment variant
    func riviumAbTesting(didAssignVariant variantKey: String, forExperiment experimentKey: String, config: [String: Any]?)

    /// Called when experiments are refreshed from the server
    func riviumAbTesting(didRefreshExperiments experiments: [Experiment])

    /// Called when feature flags are refreshed from the server
    func riviumAbTesting(didRefreshFeatureFlags flags: [FeatureFlag])
}

// Default implementations (optional methods)
public extension RiviumAbTestingDelegate {
    func riviumAbTestingDidInitialize() {}
    func riviumAbTesting(didReceiveError error: RiviumAbTestingError) {}
    func riviumAbTesting(didAssignVariant variantKey: String, forExperiment experimentKey: String, config: [String: Any]?) {}
    func riviumAbTesting(didRefreshExperiments experiments: [Experiment]) {}
    func riviumAbTesting(didRefreshFeatureFlags flags: [FeatureFlag]) {}
}
