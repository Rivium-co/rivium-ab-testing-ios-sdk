import Foundation

/// Feature Flag model
public struct FeatureFlag: Codable {
    public let key: String
    public let enabled: Bool
    public let rolloutPercentage: Int
    public let targetingRules: [String: AnyCodable]?
    public let variants: [FlagVariant]?
    public let defaultValue: AnyCodable?

    public init(
        key: String,
        enabled: Bool,
        rolloutPercentage: Int = 100,
        targetingRules: [String: AnyCodable]? = nil,
        variants: [FlagVariant]? = nil,
        defaultValue: AnyCodable? = nil
    ) {
        self.key = key
        self.enabled = enabled
        self.rolloutPercentage = rolloutPercentage
        self.targetingRules = targetingRules
        self.variants = variants
        self.defaultValue = defaultValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        rolloutPercentage = try container.decodeIfPresent(Int.self, forKey: .rolloutPercentage) ?? 100
        targetingRules = try container.decodeIfPresent([String: AnyCodable].self, forKey: .targetingRules)
        variants = try container.decodeIfPresent([FlagVariant].self, forKey: .variants)
        defaultValue = try container.decodeIfPresent(AnyCodable.self, forKey: .defaultValue)
    }
}

/// Feature Flag Variant
public struct FlagVariant: Codable {
    public let key: String
    public let value: AnyCodable?
    public let weight: Int

    public init(
        key: String,
        value: AnyCodable? = nil,
        weight: Int = 0
    ) {
        self.key = key
        self.value = value
        self.weight = weight
    }
}

/// Feature Flag Evaluation Result
public struct FlagEvaluationResult: Codable {
    public let flagKey: String?
    public let enabled: Bool
    public let value: AnyCodable?
    public let variant: String?
    public let reason: String?

    public init(
        flagKey: String? = nil,
        enabled: Bool = false,
        value: AnyCodable? = nil,
        variant: String? = nil,
        reason: String? = nil
    ) {
        self.flagKey = flagKey
        self.enabled = enabled
        self.value = value
        self.variant = variant
        self.reason = reason
    }
}
