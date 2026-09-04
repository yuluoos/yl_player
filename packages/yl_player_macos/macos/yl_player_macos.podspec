Pod::Spec.new do |s|
  s.name             = 'yl_player_macos'
  s.version          = '0.1.0-dev.1'
  s.summary          = 'macOS implementation for the yl_player playback kernel.'
  s.description      = <<-DESC
Hardware-first macOS implementation for the yl_player Flutter playback kernel.
                       DESC
  s.homepage         = 'https://pub.dev/packages/yl_player'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'yl_player contributors'
  s.source           = { :path => '.' }
  s.source_files     = 'yl_player_macos/Sources/yl_player_macos/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
