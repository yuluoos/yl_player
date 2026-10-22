Pod::Spec.new do |s|
  s.name = 'yl_player_media_core'
  s.version = '0.3.0-dev.4'
  s.summary = 'Shared Apple native media input core.'
  s.description = 'Shared media input, cancellation, buffer ownership, and FFmpeg bridge for yl_player plugins.'
  s.homepage = 'https://pub.dev/packages/yl_player_media_core'
  s.license = { :file => '../LICENSE' }
  s.author = 'yl_player contributors'
  s.source = { :path => '.' }
  s.source_files = 'yl_player_media_core/Sources/yl_player_media_core/**/*.swift'
  s.vendored_frameworks = 'yl_player_media_core/Frameworks/YlFFmpegBridge.xcframework'
  s.frameworks = 'Foundation', 'Network', 'AVFoundation', 'AudioToolbox', 'CoreMedia', 'VideoToolbox'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.ios.pod_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
