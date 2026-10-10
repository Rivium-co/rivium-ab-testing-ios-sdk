import Foundation

/// Event types for tracking user interactions
public enum EventType: String, Codable {
    // Core events
    case view
    case click
    case conversion
    case custom
    // Engagement events
    case scroll
    case formSubmit = "form_submit"
    case search
    case share
    // E-commerce events
    case addToCart = "add_to_cart"
    case removeFromCart = "remove_from_cart"
    case beginCheckout = "begin_checkout"
    case purchase
    // Media events
    case videoStart = "video_start"
    case videoComplete = "video_complete"
    // User events
    case signUp = "sign_up"
    case login
    case logout
}

/// Event model for tracking
public struct TrackEvent: Codable {
    public let experimentId: String
    public let variantId: String
    public let userId: String
    public let eventType: EventType
    public let eventName: String?
    public let eventValue: Double?
    public let properties: [String: AnyCodable]?
    public let timestamp: Int64
    /// Stable id of this event, so the service can tell a resend from a new event.
    public let clientEventId: String

    public init(
        experimentId: String,
        variantId: String,
        userId: String,
        eventType: EventType,
        eventName: String? = nil,
        eventValue: Double? = nil,
        properties: [String: Any]? = nil
    ) {
        self.experimentId = experimentId
        self.variantId = variantId
        self.userId = userId
        self.eventType = eventType
        self.eventName = eventName
        self.eventValue = eventValue
        self.properties = properties?.mapValues { AnyCodable($0) }
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        self.clientEventId = UUID().uuidString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        experimentId = try container.decode(String.self, forKey: .experimentId)
        variantId = try container.decode(String.self, forKey: .variantId)
        userId = try container.decode(String.self, forKey: .userId)
        eventType = try container.decode(EventType.self, forKey: .eventType)
        eventName = try container.decodeIfPresent(String.self, forKey: .eventName)
        eventValue = try container.decodeIfPresent(Double.self, forKey: .eventValue)
        properties = try container.decodeIfPresent([String: AnyCodable].self, forKey: .properties)
        timestamp = try container.decode(Int64.self, forKey: .timestamp)
        // Events stored by an older version have no id yet.
        clientEventId = try container.decodeIfPresent(String.self, forKey: .clientEventId) ?? UUID().uuidString
    }

    /// The same event once the service has said which variant the user has.
    internal func with(variantId: String) -> TrackEvent {
        return TrackEvent(copying: self, variantId: variantId)
    }

    private init(copying event: TrackEvent, variantId: String) {
        self.experimentId = event.experimentId
        self.variantId = variantId
        self.userId = event.userId
        self.eventType = event.eventType
        self.eventName = event.eventName
        self.eventValue = event.eventValue
        self.properties = event.properties
        self.timestamp = event.timestamp
        self.clientEventId = event.clientEventId
    }
}
