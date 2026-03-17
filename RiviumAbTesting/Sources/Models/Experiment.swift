import Foundation

/// Experiment status
public enum ExperimentStatus: String, Codable {
    case draft
    case running
    case paused
    case completed
    case archived
}

/// Experiment model
public struct Experiment: Codable {
    public let id: String
    public let key: String
    public let name: String
    public let status: ExperimentStatus
    public let trafficAllocation: Int
    public let variants: [Variant]
    public let targetingRules: [String: AnyCodable]?

    public init(
        id: String,
        key: String,
        name: String,
        status: ExperimentStatus,
        trafficAllocation: Int,
        variants: [Variant],
        targetingRules: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.status = status
        self.trafficAllocation = trafficAllocation
        self.variants = variants
        self.targetingRules = targetingRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        status = try container.decodeIfPresent(ExperimentStatus.self, forKey: .status) ?? .running
        trafficAllocation = try container.decodeIfPresent(Int.self, forKey: .trafficAllocation) ?? 100
        variants = try container.decodeIfPresent([Variant].self, forKey: .variants) ?? []
        targetingRules = try container.decodeIfPresent([String: AnyCodable].self, forKey: .targetingRules)
    }
}

/// Variant model
public struct Variant: Codable {
    public let id: String
    public let key: String
    public let name: String
    public let trafficSplit: Int
    public let isControl: Bool
    public let config: [String: AnyCodable]?

    public init(
        id: String,
        key: String,
        name: String,
        trafficSplit: Int,
        isControl: Bool,
        config: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.trafficSplit = trafficSplit
        self.isControl = isControl
        self.config = config
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        trafficSplit = try container.decodeIfPresent(Int.self, forKey: .trafficSplit) ?? 0
        isControl = try container.decodeIfPresent(Bool.self, forKey: .isControl) ?? false
        config = try container.decodeIfPresent([String: AnyCodable].self, forKey: .config)
    }
}

/// Assignment result
public struct Assignment: Codable {
    public let experimentId: String
    public let experimentKey: String
    public let variantId: String
    public let variantKey: String
    public let isControl: Bool
    public let config: [String: AnyCodable]?

    public init(
        experimentId: String,
        experimentKey: String,
        variantId: String,
        variantKey: String,
        isControl: Bool,
        config: [String: AnyCodable]? = nil
    ) {
        self.experimentId = experimentId
        self.experimentKey = experimentKey
        self.variantId = variantId
        self.variantKey = variantKey
        self.isControl = isControl
        self.config = config
    }
}

/// Type-erased Codable wrapper for Any values
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to decode value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unable to encode value"))
        }
    }
}
