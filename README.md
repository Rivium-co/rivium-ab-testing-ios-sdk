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
    .package(url: "https://github.com/Rivium-co/rivium-ab-testing-ios-sdk.git", from: "0.2.3")
]
```

### CocoaPods

```ruby
pod 'RiviumAbTestingSDK', '~> 0.2.3'
```

Then run `pod install`.

## Quick Start

```swift
import RiviumAbTesting

// 1. Initialize the SDK
let config = RiviumAbTestingConfig(
    apiKey: "rv_live_your_api_key",
    // Your server mints this for the signed-in user (see "User tokens").
    // Complete with .failure while no one is signed in.
    tokenProvider: { completion in
        MyBackend.fetchRiviumToken { result in completion(result) }
    }
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

## User tokens

The API key ships inside your app, so anyone can read it. On its own it can't
prove which user a request is for. Your server can: it holds your project's
**server secret** and mints a short-lived token for the signed-in user
(`POST https://auth.rivium.co/users/token`, or `createUserToken()` in the
Node.js SDK). The SDK sends it with every request, and the service takes the
user from the token instead of from the app.

`tokenProvider` is called when a token is needed, again shortly before it
expires, and once more if the service reports it expired; requests made at the
same time share one call. Complete with `.failure` while no one is signed in.
A provider that never calls `completion` counts as having no token after 15
seconds.

If you would rather hand tokens over yourself, leave `tokenProvider` out and
call `RiviumAbTesting.shared.setUserToken(token)` after sign-in and whenever
you refresh the token.

A token is **required**: assigning variants, tracking events and
evaluating flags are refused without one (reading the experiment and flag
lists is not, so the app can load them before anyone signs in). The same token works for Rivium Chat and Sync.

**Never put the server secret in the app.**

### Before your user signs in

You can call `initialize` before anyone is signed in. Without a token the SDK
waits instead of failing: `RiviumAbTesting.shared.isAwaitingUserToken` is
`true`, `onAwaitingUserToken` is called once, `getVariant` returns the default
you pass and nothing is sent for a user. It carries on by itself as soon as
there is a token: the variants your app asked for are fetched (the delegate's
`didAssignVariant` is called for each) and the kept events are sent.

```swift
RiviumAbTesting.shared.onAwaitingUserToken = { /* e.g. show the default experience */ }

// After sign-in
RiviumAbTesting.shared.refreshUserToken()      // with a tokenProvider: asks it again now
RiviumAbTesting.shared.setUserToken(token)     // without one: hand the token over

// After sign-out
RiviumAbTesting.shared.clearUserId()           // or setUserToken(nil)
```

Events recorded before sign-in belong to an anonymous user, and the service
credits events to the user in the token. So after sign-in only the events
recorded for that same user id are sent (call `setUserId` with the id your
server puts in the token before you track); the rest are dropped. The queue
holds at most 1,000 events and drops the oldest first.

### Switching users

A different user id (`setUserId`), a token for another user or a sign-out
(`clearUserId()`, `setUserToken(nil)`) clears the previous user's variants,
attributes, token and pending events before anything is done for the next
user. Events of the previous user that are ready are sent once more under
their own token; they are never sent under another user's token. Set the user
attributes again after a switch.

## A/B Testing

### Get Variant

```swift
// Asynchronous (recommended): waits for the service's answer
RiviumAbTesting.shared.getVariant(experimentKey: "experiment-key") { variant in
    switch variant {
    case "variant-a":
        showNewCheckout()
    default:
        showOriginalCheckout()
    }
}

// Synchronous: never blocks, safe on the main thread
let variant = RiviumAbTesting.shared.getVariant(
    experimentKey: "experiment-key",
    defaultVariant: "control"  // returned until the service has answered
)
```

The synchronous `getVariant` returns the variant the service assigned earlier
(it is kept on the device). The first time an experiment is asked for it
returns `defaultVariant` at once and fetches the assignment in the background;
the delegate's `didAssignVariant` tells you when it is there. Use the
completion form when the first answer matters. The variant always comes from
the service: the SDK never picks one on the device.

A user the service keeps out of an experiment (targeting, traffic) gets the
control variant; events you track for that experiment are then not recorded.

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
        let config = RiviumAbTestingConfig(apiKey: "rv_live_your_api_key", tokenProvider: fetchRiviumToken)
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

No SDK method stops the app when it is called before `initialize`, before the
first load has finished or before a user is signed in: getters return the
default you pass and `track…` does nothing. If the first load fails (no
network) the SDK works from its cache and loads again when the network is back.

## Offline Support

Events are queued locally (at most 1,000, kept across app launches in
Application Support) and sent 100 at a time. When the service is unreachable
or asks the SDK to slow down, the SDK waits before it tries again, and it
sends what is waiting when the network comes back.

## Configuration

```swift
let config = RiviumAbTestingConfig(
    apiKey: "rv_live_your_api_key",
    tokenProvider: fetchRiviumToken, // user token minted by your server
    debug: false,               // log to the console (development only; no keys, tokens or bodies)
    flushInterval: 10.0,        // Auto-flush interval in seconds. Leave it out to follow the send interval set in the Rivium console (30 until it is known)
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
| `clearUserId()` | Sign-out: forget the user and wait for a token |
| `setUserToken(_:)` | Hand over a user token (`nil` after sign-out) |
| `refreshUserToken()` | Ask the `tokenProvider` again now (after sign-in or sign-out) |
| `isAwaitingUserToken` | `true` while the SDK waits for a user token |
| `onAwaitingUserToken` | Called once each time the SDK starts waiting |
| `getUserId()` | Get current user ID |
| `setUserAttributes(_:)` | Set targeting attributes |
| `getVariant(experimentKey:)` | Get assigned variant (sync, never blocks) |
| `getVariant(experimentKey:completion:)` | Get assigned variant (waits for the service) |
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
