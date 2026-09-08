require 'xcodeproj'

host, platform, manager, fixtures = ARGV
project = Xcodeproj::Project.open(File.join(host, platform, 'Runner.xcodeproj'))
setting, floor = platform == 'ios' ? ['IPHONEOS_DEPLOYMENT_TARGET', '15.0'] : ['MACOSX_DEPLOYMENT_TARGET', '12.0']
([project] + project.targets).each do |object|
  object.build_configurations.each do |config|
    config.build_settings[setting] = floor
    config.build_settings['ENABLE_TESTABILITY'] = 'YES'
    config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  end
end
tests = project.targets.find { |target| target.name == 'RunnerTests' }
group = project.main_group.find_subpath('RunnerTests', false)
group.files.each { |file| file.remove_from_project }
tests.source_build_phase.files.to_a.each(&:remove_from_project)
Dir[File.join(host, platform, 'RunnerTests', '*.swift')].sort.each do |path|
  tests.source_build_phase.add_file_reference(group.new_file(File.basename(path)))
end
tests.resources_build_phase.files.to_a.each(&:remove_from_project)
Dir[File.join(host, platform, 'RunnerTests', '*')].sort.reject { |path| File.extname(path) == '.swift' || File.directory?(path) }.each do |path|
  tests.resources_build_phase.add_file_reference(group.new_file(File.basename(path)))
end
if manager == 'cocoapods'
  project.targets.each do |target|
    target.frameworks_build_phase.files.to_a.select { |file| file.product_ref }.each(&:remove_from_project) if target.respond_to?(:frameworks_build_phase)
    target.package_product_dependencies.to_a.each(&:remove_from_project) if target.respond_to?(:package_product_dependencies)
  end
  project.root_object.package_references.to_a.each(&:remove_from_project)
  project.files.select { |file| file.path&.include?('FlutterGeneratedPluginSwiftPackage') }.each(&:remove_from_project)
end
project.save
