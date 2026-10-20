Pod::Spec.new do |s|
  s.name = 'yl_player_media_delivery'
  s.version = '0.3.0-dev.3'
  s.summary = 'Independent Apple HLS media delivery for Flutter.'
  s.description = 'Optional compressed media remux, HLS origin and delivery leases without a player.'
  s.homepage = 'https://pub.dev/packages/yl_player_media_delivery'
  s.license = { :file => '../LICENSE' }
  s.author = 'yl_player contributors'
  s.source = { :path => '.' }
  s.source_files = 'yl_player_media_delivery/Sources/yl_player_media_delivery/**/*.swift'
  s.dependency 'yl_player_media_core'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.frameworks = 'AVFoundation', 'AudioToolbox', 'CoreMedia', 'Network'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
