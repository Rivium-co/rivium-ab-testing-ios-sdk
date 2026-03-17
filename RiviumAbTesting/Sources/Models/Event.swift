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
    }
}
