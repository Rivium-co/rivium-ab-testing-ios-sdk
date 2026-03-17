# Rivium AB Testing iOS SDK

A/B Testing and Feature Flags SDK for iOS with offline-first sync.

[![iOS 13+](https://img.shields.io/badge/iOS-13%2B-blue.svg)](https://developer.apple.com/ios/)
[![Swift 5.7+](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Features

- A/B testing with automatic variant assignment
- Feature flags with targeting rules and rollout percentages
- Sticky bucketing — users stay in the same variant
- Offline-first event queue with automatic sync
- 17 built-in event types (view, click, conversion, purchase, etc.)
- Delegate-based callbacks for SDK events
- Thread-safe singleton design

## Installation

### Swift Package Manager

Add the package in Xcode: **File > Add Packages** and enter:

```
https://github.com/Rivium-co/rivium-ab-testing-ios-sdk.git
```

Or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Rivium-co/rivium-ab-testing-ios-sdk.git", from: "0.1.0")
]
```

### CocoaPods

```ruby
pod 'RiviumAbTestingSDK', '~> 0.1.0'
```

Then run `pod install`.

## Quick Start

```swift
import RiviumAbTesting

// 1. Initialize the SDK
let config = RiviumAbTestingConfig(
    apiKey: "rv_live_your_api_key",
    debug: true
)
RiviumAbTesting.shared.initialize(config: config)

// 2. Set user ID
RiviumAbTesting.shared.setUserId("user-123")

// 3. Get variant for an experiment
RiviumAbTesting.shared.getVariant(experimentKey: "checkout-redesign") { variant in
    if variant == "variant-a" {
        // Show new design
    } else {
        // Show control
    }
}

// 4. Track conversion
RiviumAbTesting.shared.trackConversion(experimentKey: "checkout-redesign", value: 49.99)

// 5. Flush pending events
RiviumAbTesting.shared.flush()
```

## A/B Testing

### Get Variant

```swift
// Synchronous
let variant = RiviumAbTesting.shared.getVariant(
    experimentKey: "experiment-key",
    defaultVariant: "control"  // fallback if offline and no cache
)

// Asynchronous (recommended)
RiviumAbTesting.shared.getVariant(experimentKey: "experiment-key") { variant in
    switch variant {
    case "variant-a":
        showNewCheckout()
    default:
        showOriginalCheckout()
    }
}
```

### Get Variant Config

```swift
let config = RiviumAbTesting.shared.getVariantConfig(experimentKey: "experiment-key")
// config is a [String: Any]? set in the Rivium dashboard
let layout = config?["layout"]
let buttonColor = config?["button_color"]
```

### List Experiments

```swift
let experiments = RiviumAbTesting.shared.getExperiments()
for exp in experiments {
    print("\(exp.key) [\(exp.status.rawValue)] - \(exp.variants.count) variants")
}

// Refresh from server
RiviumAbTesting.shared.refreshExperiments()
```

## Feature Flags

```swift
// Check if feature is enabled (local evaluation)
let darkMode = RiviumAbTesting.shared.isFeatureEnabled("dark-mode")

// Async with server-side evaluation
RiviumAbTesting.shared.isFeatureEnabled("dark-mode") { enabled in
    if enabled { self.enableDarkMode() }
}

// Get feature value (string, number, JSON, etc.)
let maxUpload = RiviumAbTesting.shared.getFeatureValue("max-upload-size", defaultValue: 10)

// Get all flags
let flags = RiviumAbTesting.shared.getFeatureFlags()
for flag in flags {
    print("\(flag.key): enabled=\(flag.enabled), rollout=\(flag.rolloutPercentage)%")
}

// Refresh flags from server
RiviumAbTesting.shared.refreshFeatureFlags()
```

## Event Tracking

Track user interactions with 17 built-in event types:

```swift
// Core events
RiviumAbTesting.shared.trackView(experimentKey: "experiment-key")
RiviumAbTesting.shared.trackClick(experimentKey: "experiment-key")
RiviumAbTesting.shared.trackConversion(experimentKey: "experiment-key", value: 99.99)

// Custom event
RiviumAbTesting.shared.trackCustomEvent(
    experimentKey: "experiment-key",
    eventName: "button_tap",
    properties: ["duration_ms": 1500, "element": "cta_button"]
)

// E-commerce events
RiviumAbTesting.shared.trackAddToCart(experimentKey: "experiment-key", value: 29.99, productId: "sku-123", properties: ["quantity": 2])
RiviumAbTesting.shared.trackPurchase(experimentKey: "experiment-key", value: 59.99, transactionId: "txn-456", properties: ["currency": "USD"])
RiviumAbTesting.shared.trackRemoveFromCart(experimentKey: "experiment-key", value: 29.99, productId: "sku-123")
RiviumAbTesting.shared.trackBeginCheckout(experimentKey: "experiment-key", value: 59.99)

// Engagement events
RiviumAbTesting.shared.trackScroll(experimentKey: "experiment-key", depth: 75.0)
RiviumAbTesting.shared.trackFormSubmit(experimentKey: "experiment-key", formName: "signup")
RiviumAbTesting.shared.trackSearch(experimentKey: "experiment-key", query: "shoes")
RiviumAbTesting.shared.trackShare(experimentKey: "experiment-key", method: "twitter")

// Media events
RiviumAbTesting.shared.trackVideoStart(experimentKey: "experiment-key", videoId: "vid-001")
RiviumAbTesting.shared.trackVideoComplete(experimentKey: "experiment-key", videoId: "vid-001")

// Auth events
RiviumAbTesting.shared.trackSignUp(experimentKey: "experiment-key", method: "apple")
RiviumAbTesting.shared.trackLogin(experimentKey: "experiment-key", method: "biometric")
RiviumAbTesting.shared.trackLogout(experimentKey: "experiment-key")
```

### Generic Event Tracking

```swift
RiviumAbTesting.shared.track(
    experimentKey: "experiment-key",
    eventType: .custom,
    eventName: "page_load_time",
    eventValue: 2.3,
    properties: ["page": "/checkout", "cached": false]
)
```

## User Attributes

Set attributes for targeting rules:

```swift
RiviumAbTesting.shared.setUserId("user-123")

RiviumAbTesting.shared.setUserAttributes([
    "plan": "premium",
    "country": "US",
    "age": 28,
    "platform": "ios"
])
```

## Delegate

Listen for SDK events:

```swift
class AppDelegate: UIResponder, UIApplicationDelegate, RiviumAbTestingDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
        let config = RiviumAbTestingConfig(apiKey: "rv_live_your_api_key", debug: true)
        RiviumAbTesting.shared.initialize(config: config, delegate: self)
        return true
    }

    func riviumAbTestingDidInitialize() {
        print("SDK initialized")
    }

    func riviumAbTesting(didAssignVariant variantKey: String, forExperiment experimentKey: String, config: [String: Any]?) {
        print("Assigned: \(experimentKey) -> \(variantKey)")
    }

    func riviumAbTesting(didRefreshExperiments experiments: [Experiment]) {
        print("Refreshed \(experiments.count) experiments")
    }

    func riviumAbTesting(didRefreshFeatureFlags flags: [FeatureFlag]) {
        print("Refreshed \(flags.count) flags")
    }

    func riviumAbTesting(didReceiveError error: RiviumAbTestingError) {
        print("Error: \(error.localizedDescription)")
    }
}
```

## Configuration

```swift
let config = RiviumAbTestingConfig(
    apiKey: "rv_live_your_api_key",
    debug: true,                // Enable debug logging
    flushInterval: 10.0,        // Auto-flush interval in seconds (default: 30)
    maxQueueSize: 50            // Max events before auto-flush (default: 100)
)
```

## Lifecycle

```swift
// Refresh experiments from server
RiviumAbTesting.shared.refreshExperiments()

// Reset all state (clears cache, assignments, events)
RiviumAbTesting.shared.reset()

// Flush pending events
RiviumAbTesting.shared.flush()
```

## API Reference

| Method | Description |
|---|---|
| `initialize(config:delegate:)` | Initialize the SDK |
| `setUserId(_:)` | Set user ID for assignment |
| `getUserId()` | Get current user ID |
| `setUserAttributes(_:)` | Set targeting attributes |
| `getVariant(experimentKey:)` | Get assigned variant (sync) |
| `getVariant(experimentKey:completion:)` | Get assigned variant (async) |
| `getVariantConfig(experimentKey:)` | Get variant configuration |
| `isFeatureEnabled(_:)` | Check if feature flag is on (local) |
| `isFeatureEnabled(_:completion:)` | Check flag with server eval |
| `getFeatureValue(_:defaultValue:)` | Get feature flag value |
| `getFeatureFlags()` | Get all feature flags |
| `refreshFeatureFlags()` | Refresh flags from server |
| `refreshExperiments()` | Refresh experiments from server |
| `getExperiments()` | Get all experiments |
| `flush()` | Force sync pending events |
| `reset()` | Clear all state and cache |

## Example App

See the `Example/` directory for a complete working SwiftUI example.

## Documentation

- [Rivium Console](https://console.rivium.co)
- [iOS SDK Docs](https://console.rivium.co/dashboard/rivium-abtest/docs/ios)

## License

MIT
