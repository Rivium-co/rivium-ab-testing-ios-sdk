import Foundation

internal class Storage {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let userId = "rivium_ab_testing_user_id"
        static let experiments = "rivium_ab_testing_experiments"
        static let featureFlags = "rivium_ab_testing_feature_flags"
        static let assignments = "rivium_ab_testing_assignments"
        static let userAttributes = "rivium_ab_testing_user_attributes"
        static let userIdGenerated = "rivium_ab_testing_user_id_generated"
    }

    private let assignmentLock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var userId: String? {
        get { defaults.string(forKey: Keys.userId) }
        set { defaults.set(newValue, forKey: Keys.userId) }
    }

    /// True while `userId` is the random id the SDK made for a user who has
    /// not signed in. When unknown (an install from an older version) an id
    /// that looks like the SDK's random ids counts as one.
    var userIdGenerated: Bool {
        get {
            if let known = defaults.object(forKey: Keys.userIdGenerated) as? Bool { return known }
            guard let userId = userId else { return true }
            return UUID(uuidString: userId) != nil
        }
        set { defaults.set(newValue, forKey: Keys.userIdGenerated) }
    }

    var userAttributes: [String: Any]? {
        get {
            guard let data = defaults.data(forKey: Keys.userAttributes) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        set {
            guard let newValue = newValue,
                  let data = try? JSONSerialization.data(withJSONObject: newValue) else {
                defaults.removeObject(forKey: Keys.userAttributes)
                return
            }
            defaults.set(data, forKey: Keys.userAttributes)
        }
    }

    func saveExperiments(_ experiments: [Experiment]) {
        guard let data = try? encoder.encode(experiments) else { return }
        defaults.set(data, forKey: Keys.experiments)
    }

    func getExperiments() -> [Experiment] {
        guard let data = defaults.data(forKey: Keys.experiments),
              let experiments = try? decoder.decode([Experiment].self, from: data) else {
            return []
        }
        return experiments
    }

    func saveFeatureFlags(_ flags: [FeatureFlag]) {
        guard let data = try? encoder.encode(flags) else { return }
        defaults.set(data, forKey: Keys.featureFlags)
    }

    func getFeatureFlags() -> [FeatureFlag] {
        guard let data = defaults.data(forKey: Keys.featureFlags),
              let flags = try? decoder.decode([FeatureFlag].self, from: data) else {
            return []
        }
        return flags
    }

    func saveAssignment(_ assignment: Assignment, forExperimentKey key: String) {
        assignmentLock.lock()
        defer { assignmentLock.unlock() }
        var assignments = getAssignments()
        assignments[key] = assignment
        guard let data = try? encoder.encode(assignments) else { return }
        defaults.set(data, forKey: Keys.assignments)
    }

    func getAssignment(forExperimentKey key: String) -> Assignment? {
        return getAssignments()[key]
    }

    func getAssignments() -> [String: Assignment] {
        guard let data = defaults.data(forKey: Keys.assignments),
              let assignments = try? decoder.decode([String: Assignment].self, from: data) else {
            return [:]
        }
        return assignments
    }

    /// Forget the assignments that say "not in the experiment", so the service is asked again.
    func clearOutsideAssignments() {
        assignmentLock.lock()
        defer { assignmentLock.unlock() }
        let assignments = getAssignments()
        let kept = assignments.filter { $0.value.inExperiment != false }
        guard kept.count != assignments.count, let data = try? encoder.encode(kept) else { return }
        defaults.set(data, forKey: Keys.assignments)
    }

    func clearAssignments() {
        assignmentLock.lock()
        defer { assignmentLock.unlock() }
        defaults.removeObject(forKey: Keys.assignments)
    }

    func clear() {
        defaults.removeObject(forKey: Keys.userId)
        defaults.removeObject(forKey: Keys.experiments)
        defaults.removeObject(forKey: Keys.featureFlags)
        defaults.removeObject(forKey: Keys.assignments)
        defaults.removeObject(forKey: Keys.userAttributes)
        defaults.removeObject(forKey: Keys.userIdGenerated)
    }
}
