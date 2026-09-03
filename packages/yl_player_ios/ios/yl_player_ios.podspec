#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint yl_player_ios.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'yl_player_ios'
  s.version          = '0.1.0-dev.1'
  s.summary          = 'iOS implementation for the yl_player playback kernel.'
  s.description      = <<-DESC
Hardware-first iOS implementation for the yl_player Flutter playback kernel.
                       DESC
  s.homepage         = 'https://pub.dev/packages/yl_player'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'yl_player contributors'
  s.source           = { :path => '.' }
  s.source_files = 'yl_player_ios/Sources/yl_player_ios/**/*'
  s.vendored_frameworks = 'yl_player_ios/Frameworks/YlFFmpegBridge.xcframework'
  s.frameworks = 'AVFoundation', 'AudioToolbox', 'CoreMedia', 'VideoToolbox', 'AVFAudio'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'yl_player_ios_privacy' => ['yl_player_ios/Sources/yl_player_ios/PrivacyInfo.xcprivacy']}
end
