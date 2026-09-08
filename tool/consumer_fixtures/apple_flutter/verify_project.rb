require 'json'
require 'xcodeproj'

host, platform, manager = ARGV
setting, floor = platform == 'ios' ? ['IPHONEOS_DEPLOYMENT_TARGET', '15.0'] : ['MACOSX_DEPLOYMENT_TARGET', '12.0']
paths = [File.join(host, platform, 'Runner.xcodeproj')]
paths << File.join(host, platform, 'Pods/Pods.xcodeproj') if manager == 'cocoapods'
evidence = []
paths.each do |path|
  project = Xcodeproj::Project.open(path)
  ([project] + project.targets).each do |object|
    # CocoaPods' project-level default can be absent; every concrete pod target is explicit.
    next if object == project && path.include?('/Pods/')
    object.build_configurations.each do |config|
      actual = config.build_settings[setting]
      raise "Wrong floor #{path}:#{object.name}:#{config.name}: #{actual}" unless actual == floor
      evidence << { project: path, target: object.respond_to?(:name) ? object.name : 'project', configuration: config.name, floor: actual }
    end
  end
end
puts JSON.pretty_generate(evidence)
