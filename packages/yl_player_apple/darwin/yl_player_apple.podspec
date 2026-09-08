Pod::Spec.new do |s|
  s.name             = 'yl_player_apple'
  s.version          = '0.2.0-dev.1'
  s.summary          = 'Shared iOS and macOS implementation for yl_player.'
  s.description      = <<-DESC
Shared Apple implementation for the yl_player Flutter playback kernel.
                       DESC
  s.homepage         = 'https://pub.dev/packages/yl_player'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'yl_player contributors'
  s.source           = { :path => '.' }
  s.source_files     = 'yl_player_apple/Sources/yl_player_apple/**/*.swift'
  s.vendored_frameworks = 'yl_player_apple/Frameworks/YlFFmpegBridge.xcframework'

  s.frameworks = 'AVFoundation', 'AudioToolbox', 'CoreMedia', 'VideoToolbox', 'AVFAudio', 'Network', 'QuartzCore'
  s.ios.frameworks = 'UIKit'
  s.osx.frameworks = 'AppKit'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.ios.pod_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
