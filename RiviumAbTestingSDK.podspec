Pod::Spec.new do |s|
  s.name             = 'RiviumAbTestingSDK'
  s.version          = '0.2.1'
  s.summary          = 'A/B Testing and Feature Flags SDK for iOS with offline-first sync.'
  s.description      = <<-DESC
RiviumAbTesting is a powerful A/B testing and feature flags SDK for iOS.
Run experiments, manage feature flags with targeting rules and rollout percentages,
and track 17 built-in event types with offline-first event queue.
                       DESC
  s.homepage         = 'https://github.com/Rivium-co/rivium-ab-testing-ios-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Rivium' => 'founder@rivium.co' }
  s.source           = { :git => 'https://github.com/Rivium-co/rivium-ab-testing-ios-sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_version = '5.7'

  s.source_files = 'RiviumAbTesting/Sources/**/*.swift'

  s.frameworks = 'Foundation', 'UIKit'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
