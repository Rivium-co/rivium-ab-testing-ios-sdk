import SwiftUI
import RiviumAbTesting

// MARK: - Constants
private let apiKey = "YOUR_API_KEY_HERE"
private let experimentKeys = ["checkout-flow-test", "pricing-page-test"]
private let featureFlagKeys = ["dark_mode", "onboarding_flow", "dark_mode_settings", "holiday_banner"]

struct ContentView: View {
    @StateObject private var viewModel = TestViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Status Bar
                statusBar

                // Log Panel + Buttons
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        // Log Panel (top half)
                        logPanel
                            .frame(height: geometry.size.height * 0.45)

                        Divider()

                        // Button sections (bottom half)
                        ScrollView {
                            VStack(spacing: 16) {
                                runFullScenarioButton
                                setupSection
                                experimentsSection
                                coreEventsSection
                                engagementEventsSection
                                ecommerceEventsSection
                                mediaEventsSection
                                authEventsSection
                                featureFlagsSection
                                advancedSection
                                lifecycleSection
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("RiviumAbTesting iOS")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.isInitialized ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.isInitialized ? "SDK Ready" : "Not Initialized")
                        .font(.caption2)
                }

                if let variant = viewModel.currentVariant {
                    chipView(text: "Variant: \(variant)", color: .purple)
                }

                if viewModel.variantConfig != nil {
                    chipView(text: "Config: \(viewModel.variantConfig!.count) keys", color: .blue)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGray6))
    }

    private func chipView(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(12)
    }

    // MARK: - Log Panel

    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.logs) { log in
                        Text(log.message)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(log.color)
                            .id(log.id)
                    }
                }
                .padding(8)
            }
            .background(Color.black)
            .onChange(of: viewModel.logs.count) { _ in
                if let last = viewModel.logs.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Run Full Scenario

    private var runFullScenarioButton: some View {
        Button(action: { viewModel.runFullScenario() }) {
            HStack {
                Image(systemName: "play.fill")
                Text("Run Full Scenario")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.purple)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }

    // MARK: - Sections

    private var setupSection: some View {
        SectionView(title: "Setup", icon: "gearshape.fill", color: .blue) {
            FlowLayout(spacing: 8) {
                TestButton("Init SDK") { viewModel.initSDK() }
                TestButton("Set User") { viewModel.setUser() }
                TestButton("Set Attributes") { viewModel.setAttributes() }
            }
        }
    }

    private var experimentsSection: some View {
        SectionView(title: "Experiments", icon: "flask.fill", color: .purple) {
            FlowLayout(spacing: 8) {
                TestButton("Get Variant") { viewModel.getVariant() }
                TestButton("Get Config") { viewModel.getVariantConfig() }
                TestButton("List Experiments") { viewModel.listExperiments() }
                TestButton("Refresh") { viewModel.refreshExperiments() }
            }
        }
    }

    private var coreEventsSection: some View {
        SectionView(title: "Core Events", icon: "bolt.fill", color: .orange) {
            FlowLayout(spacing: 8) {
                TestButton("View") { viewModel.trackView() }
                TestButton("Click") { viewModel.trackClick() }
                TestButton("Conversion") { viewModel.trackConversion() }
                TestButton("Custom") { viewModel.trackCustomEvent() }
                TestButton("Generic") { viewModel.trackGenericEvent() }
            }
        }
    }

    private var engagementEventsSection: some View {
        SectionView(title: "Engagement Events", icon: "hand.tap.fill", color: .teal) {
            FlowLayout(spacing: 8) {
                TestButton("Scroll") { viewModel.trackScroll() }
                TestButton("Form Submit") { viewModel.trackFormSubmit() }
                TestButton("Search") { viewModel.trackSearch() }
                TestButton("Share") { viewModel.trackShare() }
            }
        }
    }

    private var ecommerceEventsSection: some View {
        SectionView(title: "E-Commerce Events", icon: "cart.fill", color: .green) {
            FlowLayout(spacing: 8) {
                TestButton("Add to Cart") { viewModel.trackAddToCart() }
                TestButton("Remove from Cart") { viewModel.trackRemoveFromCart() }
                TestButton("Begin Checkout") { viewModel.trackBeginCheckout() }
                TestButton("Purchase") { viewModel.trackPurchase() }
            }
        }
    }

    private var mediaEventsSection: some View {
        SectionView(title: "Media Events", icon: "play.rectangle.fill", color: .red) {
            FlowLayout(spacing: 8) {
                TestButton("Video Start") { viewModel.trackVideoStart() }
                TestButton("Video Complete") { viewModel.trackVideoComplete() }
            }
        }
    }

    private var authEventsSection: some View {
        SectionView(title: "Auth Events", icon: "person.fill", color: .indigo) {
            FlowLayout(spacing: 8) {
                TestButton("Sign Up") { viewModel.trackSignUp() }
                TestButton("Login") { viewModel.trackLogin() }
                TestButton("Logout") { viewModel.trackLogout() }
            }
        }
    }

    private var featureFlagsSection: some View {
        SectionView(title: "Feature Flags", icon: "flag.fill", color: .mint) {
            FlowLayout(spacing: 8) {
                TestButton("Check dark_mode") { viewModel.checkFlag("dark_mode") }
                TestButton("Check onboarding_flow") { viewModel.checkFlag("onboarding_flow") }
                TestButton("Get Value") { viewModel.getFlagValue() }
                TestButton("List Flags") { viewModel.listFlags() }
                TestButton("Refresh Flags") { viewModel.refreshFlags() }
                TestButton("Server Eval") { viewModel.serverEvalFlag() }
            }
        }
    }

    private var advancedSection: some View {
        SectionView(title: "Advanced", icon: "wrench.fill", color: .gray) {
            FlowLayout(spacing: 8) {
                TestButton("Multi-User Test") { viewModel.multiUserTest() }
            }
        }
    }

    private var lifecycleSection: some View {
        SectionView(title: "Lifecycle", icon: "arrow.triangle.2.circlepath", color: .pink) {
            FlowLayout(spacing: 8) {
                TestButton("Flush") { viewModel.flushEvents() }
                TestButton("Reset") { viewModel.resetSDK() }
                TestButton("Clear Logs") { viewModel.clearLogs() }
            }
        }
    }
}

// MARK: - Section View

struct SectionView<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Test Button

struct TestButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray5))
                .foregroundColor(.primary)
                .cornerRadius(8)
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    let color: Color
}

// MARK: - View Model

class TestViewModel: ObservableObject, RiviumAbTestingDelegate {
    @Published var logs: [LogEntry] = []
    @Published var isInitialized = false
    @Published var currentVariant: String?
    @Published var variantConfig: [String: Any]?

    private let sdk = RiviumAbTesting.shared
    private var currentExperiment: String { experimentKeys[0] }

    // MARK: - Logging

    func log(_ message: String, color: Color = .white) {
        DispatchQueue.main.async {
            self.logs.append(LogEntry(message: message, color: color))
        }
    }

    func logSection(_ title: String) {
        log("--- \(title) ---", color: .yellow)
    }

    func logSuccess(_ message: String) {
        log(message, color: .green)
    }

    func logError(_ message: String) {
        log(message, color: .red)
    }

    // MARK: - Run Full Scenario

    func runFullScenario() {
        logSection("FULL SCENARIO")
        log("Starting comprehensive SDK test...")

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }

            // 1. Init
            self.logSection("1. Initialize SDK")
            self.initSDK()
            Thread.sleep(forTimeInterval: 2.0)

            // 2. Set User
            self.logSection("2. Set User")
            self.setUser()
            self.setAttributes()
            Thread.sleep(forTimeInterval: 0.5)

            // 3. Experiments
            self.logSection("3. Experiments")
            self.getVariant()
            Thread.sleep(forTimeInterval: 1.5)
            self.getVariantConfig()
            self.listExperiments()
            Thread.sleep(forTimeInterval: 0.5)

            // 4. Core Events
            self.logSection("4. Core Events")
            self.trackView()
            self.trackClick()
            self.trackConversion()
            self.trackCustomEvent()
            self.trackGenericEvent()
            Thread.sleep(forTimeInterval: 0.5)

            // 5. Engagement Events
            self.logSection("5. Engagement Events")
            self.trackScroll()
            self.trackFormSubmit()
            self.trackSearch()
            self.trackShare()
            Thread.sleep(forTimeInterval: 0.5)

            // 6. E-Commerce Events
            self.logSection("6. E-Commerce Events")
            self.trackAddToCart()
            self.trackRemoveFromCart()
            self.trackBeginCheckout()
            self.trackPurchase()
            Thread.sleep(forTimeInterval: 0.5)

            // 7. Media Events
            self.logSection("7. Media Events")
            self.trackVideoStart()
            self.trackVideoComplete()
            Thread.sleep(forTimeInterval: 0.5)

            // 8. Auth Events
            self.logSection("8. Auth Events")
            self.trackSignUp()
            self.trackLogin()
            self.trackLogout()
            Thread.sleep(forTimeInterval: 0.5)

            // 9. Feature Flags
            self.logSection("9. Feature Flags")
            for key in featureFlagKeys {
                self.checkFlag(key)
            }
            self.getFlagValue()
            self.listFlags()
            Thread.sleep(forTimeInterval: 0.5)

            // 10. Multi-user test
            self.logSection("10. Multi-User Test")
            self.multiUserTest()
            Thread.sleep(forTimeInterval: 3.0)

            // 11. Flush
            self.logSection("11. Flush & Complete")
            self.flushEvents()
            Thread.sleep(forTimeInterval: 1.0)

            self.log("")
            self.logSuccess("=== FULL SCENARIO COMPLETE ===")
        }
    }

    // MARK: - Setup

    func initSDK() {
        log("Initializing SDK...")
        let config = RiviumAbTestingConfig(
            apiKey: apiKey,
            debug: true,
            flushInterval: 10.0,
            maxQueueSize: 50
        )
        sdk.initialize(config: config, delegate: self)
        logSuccess("SDK initialization started")
    }

    func setUser() {
        let userId = "ios-test-user-\(Int.random(in: 1000...9999))"
        sdk.setUserId(userId)
        logSuccess("User set: \(userId)")
    }

    func setAttributes() {
        let attributes: [String: Any] = [
            "plan": "premium",
            "country": "US",
            "age": 28,
            "appVersion": "2.1.0",
            "platform": "ios"
        ]
        sdk.setUserAttributes(attributes)
        logSuccess("Attributes set: \(attributes.count) keys")
    }

    // MARK: - Experiments

    func getVariant() {
        log("Getting variant for \(currentExperiment)...")
        sdk.getVariant(experimentKey: currentExperiment) { [weak self] variant in
            DispatchQueue.main.async {
                self?.currentVariant = variant
                self?.logSuccess("Variant: \(variant)")
            }
        }
    }

    func getVariantConfig() {
        let config = sdk.getVariantConfig(experimentKey: currentExperiment)
        DispatchQueue.main.async {
            self.variantConfig = config
            if let config = config {
                self.logSuccess("Config: \(config)")
            } else {
                self.log("No config for \(self.currentExperiment)")
            }
        }
    }

    func listExperiments() {
        let experiments = sdk.getExperiments()
        logSuccess("Experiments: \(experiments.count)")
        for exp in experiments {
            log("  - \(exp.key) (\(exp.status.rawValue)) \(exp.variants.count) variants")
        }
    }

    func refreshExperiments() {
        log("Refreshing experiments...")
        sdk.refreshExperiments {
            self.logSuccess("Experiments refreshed")
        }
    }

    // MARK: - Core Events

    func trackView() {
        sdk.trackView(experimentKey: currentExperiment)
        logSuccess("Tracked: view")
    }

    func trackClick() {
        sdk.trackClick(experimentKey: currentExperiment)
        logSuccess("Tracked: click")
    }

    func trackConversion() {
        sdk.trackConversion(experimentKey: currentExperiment, value: 49.99)
        logSuccess("Tracked: conversion ($49.99)")
    }

    func trackCustomEvent() {
        sdk.trackCustomEvent(
            experimentKey: currentExperiment,
            eventName: "button_tap",
            properties: ["screen": "home", "element": "hero_banner"]
        )
        logSuccess("Tracked: custom (button_tap)")
    }

    func trackGenericEvent() {
        sdk.track(
            experimentKey: currentExperiment,
            eventType: .click,
            eventName: "generic_test",
            eventValue: 1.0,
            properties: ["source": "ios_example"]
        )
        logSuccess("Tracked: generic (click)")
    }

    // MARK: - Engagement Events

    func trackScroll() {
        sdk.trackScroll(experimentKey: currentExperiment, depth: 75.0, properties: ["page": "product_list"])
        logSuccess("Tracked: scroll (75%)")
    }

    func trackFormSubmit() {
        sdk.trackFormSubmit(experimentKey: currentExperiment, formName: "checkout_form", properties: ["fields": 5])
        logSuccess("Tracked: form_submit")
    }

    func trackSearch() {
        sdk.trackSearch(experimentKey: currentExperiment, query: "premium plan", properties: ["results": 12])
        logSuccess("Tracked: search")
    }

    func trackShare() {
        sdk.trackShare(experimentKey: currentExperiment, method: "twitter", properties: ["contentType": "product"])
        logSuccess("Tracked: share")
    }

    // MARK: - E-Commerce Events

    func trackAddToCart() {
        sdk.trackAddToCart(experimentKey: currentExperiment, value: 29.99, productId: "PROD-001", properties: ["quantity": 1])
        logSuccess("Tracked: add_to_cart ($29.99)")
    }

    func trackRemoveFromCart() {
        sdk.trackRemoveFromCart(experimentKey: currentExperiment, value: 29.99, productId: "PROD-001")
        logSuccess("Tracked: remove_from_cart")
    }

    func trackBeginCheckout() {
        sdk.trackBeginCheckout(experimentKey: currentExperiment, value: 59.98, properties: ["items": 2])
        logSuccess("Tracked: begin_checkout ($59.98)")
    }

    func trackPurchase() {
        sdk.trackPurchase(experimentKey: currentExperiment, value: 59.98, transactionId: "TXN-\(Int.random(in: 10000...99999))", properties: ["currency": "USD"])
        logSuccess("Tracked: purchase ($59.98)")
    }

    // MARK: - Media Events

    func trackVideoStart() {
        sdk.trackVideoStart(experimentKey: currentExperiment, videoId: "onboarding-v2", properties: ["duration": 120])
        logSuccess("Tracked: video_start")
    }

    func trackVideoComplete() {
        sdk.trackVideoComplete(experimentKey: currentExperiment, videoId: "onboarding-v2", properties: ["watchTime": 118])
        logSuccess("Tracked: video_complete")
    }

    // MARK: - Auth Events

    func trackSignUp() {
        sdk.trackSignUp(experimentKey: currentExperiment, method: "apple", properties: ["source": "onboarding"])
        logSuccess("Tracked: sign_up (apple)")
    }

    func trackLogin() {
        sdk.trackLogin(experimentKey: currentExperiment, method: "biometric", properties: ["device": "iPhone"])
        logSuccess("Tracked: login (biometric)")
    }

    func trackLogout() {
        sdk.trackLogout(experimentKey: currentExperiment, properties: ["sessionDuration": 3600])
        logSuccess("Tracked: logout")
    }

    // MARK: - Feature Flags

    func checkFlag(_ key: String) {
        let enabled = sdk.isFeatureEnabled(key)
        logSuccess("Flag '\(key)': \(enabled ? "ENABLED" : "DISABLED")")
    }

    func getFlagValue() {
        let value = sdk.getFeatureValue("dark_mode_settings", defaultValue: "default")
        logSuccess("Flag value dark_mode_settings: \(value ?? "nil")")
    }

    func listFlags() {
        let flags = sdk.getFeatureFlags()
        logSuccess("Feature flags: \(flags.count)")
        for flag in flags {
            let status = flag.enabled ? "ON" : "OFF"
            log("  - \(flag.key) [\(status)] rollout: \(flag.rolloutPercentage)%")
        }
    }

    func refreshFlags() {
        log("Refreshing feature flags...")
        sdk.refreshFeatureFlags {
            self.logSuccess("Feature flags refreshed")
        }
    }

    func serverEvalFlag() {
        log("Server evaluating dark_mode...")
        sdk.isFeatureEnabled("dark_mode", defaultValue: false) { [weak self] enabled in
            self?.logSuccess("Server eval dark_mode: \(enabled ? "ENABLED" : "DISABLED")")
        }
    }

    // MARK: - Advanced

    func multiUserTest() {
        log("Running multi-user test (20 users)...")
        var variantCounts: [String: Int] = [:]

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }

            for i in 1...20 {
                let userId = "multi-user-\(i)"
                self.sdk.setUserId(userId)

                let semaphore = DispatchSemaphore(value: 0)
                var variant = "control"

                self.sdk.getVariant(experimentKey: self.currentExperiment) { v in
                    variant = v
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 3)

                variantCounts[variant, default: 0] += 1
            }

            DispatchQueue.main.async {
                self.logSuccess("Multi-user results:")
                for (variant, count) in variantCounts.sorted(by: { $0.key < $1.key }) {
                    self.log("  \(variant): \(count)/20 (\(count * 100 / 20)%)")
                }
            }
        }
    }

    // MARK: - Lifecycle

    func flushEvents() {
        sdk.flush()
        logSuccess("Events flushed")
    }

    func resetSDK() {
        sdk.reset()
        DispatchQueue.main.async {
            self.isInitialized = false
            self.currentVariant = nil
            self.variantConfig = nil
            self.logSuccess("SDK reset")
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - RiviumAbTestingDelegate

    func riviumAbTestingDidInitialize() {
        DispatchQueue.main.async {
            self.isInitialized = true
            self.logSuccess("SDK initialized successfully")
        }
    }

    func riviumAbTesting(didReceiveError error: RiviumAbTestingError) {
        logError("SDK Error: \(error.localizedDescription)")
    }

    func riviumAbTesting(didAssignVariant variantKey: String, forExperiment experimentKey: String, config: [String: Any]?) {
        DispatchQueue.main.async {
            self.currentVariant = variantKey
            self.variantConfig = config
        }
        logSuccess("Assigned: \(experimentKey) -> \(variantKey)")
    }

    func riviumAbTesting(didRefreshExperiments experiments: [Experiment]) {
        logSuccess("Experiments refreshed: \(experiments.count)")
    }

    func riviumAbTesting(didRefreshFeatureFlags flags: [FeatureFlag]) {
        logSuccess("Feature flags refreshed: \(flags.count)")
    }
}

#Preview {
    ContentView()
}
