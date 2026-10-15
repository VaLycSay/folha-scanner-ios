require 'xcodeproj'
require 'fileutils'

root = File.expand_path(ARGV.fetch(0))
source = File.expand_path(ARGV.fetch(1))
project_path = File.join(root, 'iosApp/iosApp.xcodeproj')
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |t| t.name == 'iosApp' }
raise 'Original iOS target missing' unless app
raise 'Regression target already exists' if project.targets.any? { |t| t.name == 'NuvioRegressionUITests' }
tests = project.new_target(:ui_test_bundle, 'NuvioRegressionUITests', :ios, '16.1')
tests.add_dependency(app)
tests.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.valyc.nuvio.regression'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['TEST_TARGET_NAME'] = 'iosApp'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end
target_dir = File.join(root, 'iosApp/NuvioRegressionUITests')
FileUtils.mkdir_p(target_dir)
FileUtils.cp(source, File.join(target_dir, 'NuvioSmokeUITests.swift'))
group = project.main_group.new_group('NuvioRegressionUITests', 'NuvioRegressionUITests')
tests.add_file_references([group.new_file('NuvioSmokeUITests.swift')])
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests)
scheme.save_as(project_path, 'NuvioRegression', true)
puts 'Added isolated UI smoke tests; original app scheme preserved.'
