#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates GarminDataFieldService.xcodeproj from scratch. Idempotent: deletes
# any existing project before regenerating so re-running always produces a
# clean result. Conventions (build settings, framework linking, embed-phase
# shape, SPM product wiring) are copied from NightscoutService.xcodeproj and
# GarminService.xcodeproj, the two reference Loop service plugin projects in
# this workspace.

require 'xcodeproj'
require 'securerandom'
require 'fileutils'

ROOT = File.expand_path(File.join(__dir__, '..'))
PROJECT_PATH = File.join(ROOT, 'GarminDataFieldService.xcodeproj')

IPHONEOS_DEPLOYMENT_TARGET = '15.1'
SWIFT_VERSION = '5.0'
BUNDLE_ID_BASE = 'com.loopkit.GarminDataFieldService'
CONNECTIQ_PACKAGE_URL = 'https://github.com/garmin/connectiq-companion-app-sdk-ios'
CONNECTIQ_VERSION = '1.8.0'

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastSwiftUpdateCheck'] = '1540'
project.root_object.attributes['LastUpgradeCheck'] = '1540'
project.root_object.attributes['ORGANIZATIONNAME'] = 'LoopKit Authors'

# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------

main_group = project.main_group
common_group = main_group.new_group('Common', 'Common')
kit_group = main_group.new_group('GarminDataFieldServiceKit', 'GarminDataFieldServiceKit')
kitui_group = main_group.new_group('GarminDataFieldServiceKitUI', 'GarminDataFieldServiceKitUI')
plugin_group = main_group.new_group('GarminDataFieldServiceKitPlugin', 'GarminDataFieldServiceKitPlugin')
frameworks_group = main_group.new_group('Frameworks', nil)
frameworks_group.source_tree = '<group>'
products_group = project.products_group

# ---------------------------------------------------------------------------
# Framework file references (BUILT_PRODUCTS_DIR, produced elsewhere in the
# workspace via implicit dependency, exactly like NightscoutService.xcodeproj)
# ---------------------------------------------------------------------------

loopkit_framework_ref = frameworks_group.new_file('LoopKit.framework')
loopkit_framework_ref.source_tree = 'BUILT_PRODUCTS_DIR'
loopkit_framework_ref.include_in_index = nil
loopkit_framework_ref.set_explicit_file_type('wrapper.framework')

loopkitui_framework_ref = frameworks_group.new_file('LoopKitUI.framework')
loopkitui_framework_ref.source_tree = 'BUILT_PRODUCTS_DIR'
loopkitui_framework_ref.include_in_index = nil
loopkitui_framework_ref.set_explicit_file_type('wrapper.framework')

# ---------------------------------------------------------------------------
# Common sources
# ---------------------------------------------------------------------------

localized_string_ref = common_group.new_file(File.join(ROOT, 'Common', 'LocalizedString.swift'))

# ---------------------------------------------------------------------------
# GarminDataFieldServiceKit target
# ---------------------------------------------------------------------------

kit_info_plist_ref = kit_group.new_file(File.join(ROOT, 'GarminDataFieldServiceKit', 'Info.plist'))

kit_source_files = %w[
  GarminDataFieldService.swift
  GarminDeviceSession.swift
  GarminWatchApp.swift
  GarminWatchState.swift
  HKUnit.swift
  WatchStateBuilder.swift
].map { |name| kit_group.new_file(File.join(ROOT, 'GarminDataFieldServiceKit', name)) }

kit_target = project.new_target(:framework, 'GarminDataFieldServiceKit', :ios, IPHONEOS_DEPLOYMENT_TARGET)
kit_target.build_configurations.each do |config|
  config.build_settings['INFOPLIST_FILE'] = 'GarminDataFieldServiceKit/Info.plist'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID_BASE
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME:c99extidentifier)'
  config.build_settings['DEFINES_MODULE'] = 'YES'
  config.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = ''
  config.build_settings['DYLIB_COMPATIBILITY_VERSION'] = '1'
  config.build_settings['DYLIB_CURRENT_VERSION'] = '1'
  config.build_settings['DYLIB_INSTALL_NAME_BASE'] = '@rpath'
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = '$(inherited)'
  config.build_settings['INSTALL_PATH'] = '$(LOCAL_LIBRARY_DIR)/Frameworks'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
  config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = ''
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['SUPPORTS_MACCATALYST'] = 'NO'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['SWIFT_VERSION'] = SWIFT_VERSION
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['VERSIONING_SYSTEM'] = 'apple-generic'
end

kit_target.add_file_references(kit_source_files + [localized_string_ref])
kit_target.frameworks_build_phases.add_file_reference(loopkit_framework_ref, true)

# Fix up product reference to live in Products group
kit_product_ref = kit_target.product_reference
products_group.children.delete(kit_product_ref) if kit_product_ref.parent != products_group

# ---------------------------------------------------------------------------
# GarminDataFieldServiceKitUI target
# ---------------------------------------------------------------------------

kitui_info_plist_ref = kitui_group.new_file(File.join(ROOT, 'GarminDataFieldServiceKitUI', 'Info.plist'))

kitui_source_files = %w[
  GarminDataFieldService+UI.swift
  GarminDataFieldServiceSettingsView.swift
].map { |name| kitui_group.new_file(File.join(ROOT, 'GarminDataFieldServiceKitUI', name)) }

garmin_icon_ref = kitui_group.new_file(File.join(ROOT, 'GarminDataFieldServiceKitUI', 'garmin_icon.png'))

kitui_target = project.new_target(:framework, 'GarminDataFieldServiceKitUI', :ios, IPHONEOS_DEPLOYMENT_TARGET)
kitui_target.build_configurations.each do |config|
  config.build_settings['INFOPLIST_FILE'] = 'GarminDataFieldServiceKitUI/Info.plist'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_ID_BASE}UI"
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME:c99extidentifier)'
  config.build_settings['DEFINES_MODULE'] = 'YES'
  config.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = ''
  config.build_settings['DYLIB_COMPATIBILITY_VERSION'] = '1'
  config.build_settings['DYLIB_CURRENT_VERSION'] = '1'
  config.build_settings['DYLIB_INSTALL_NAME_BASE'] = '@rpath'
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = '$(inherited)'
  config.build_settings['INSTALL_PATH'] = '$(LOCAL_LIBRARY_DIR)/Frameworks'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
  config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = ''
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['SUPPORTS_MACCATALYST'] = 'NO'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['SWIFT_VERSION'] = SWIFT_VERSION
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['VERSIONING_SYSTEM'] = 'apple-generic'
end

kitui_target.add_file_references(kitui_source_files + [localized_string_ref])
kitui_target.resources_build_phase.add_file_reference(garmin_icon_ref)
kitui_target.frameworks_build_phases.add_file_reference(loopkit_framework_ref, true)
kitui_target.frameworks_build_phases.add_file_reference(loopkitui_framework_ref, true)
kitui_target.add_dependency(kit_target)
kit_product_file_ref_for_kitui = kit_target.product_reference
kitui_target.frameworks_build_phases.add_file_reference(kit_product_file_ref_for_kitui, true)

# ---------------------------------------------------------------------------
# GarminDataFieldServiceKitPlugin target
# ---------------------------------------------------------------------------

plugin_info_plist_ref = plugin_group.new_file(File.join(ROOT, 'GarminDataFieldServiceKitPlugin', 'Info.plist'))
plugin_source_files = [plugin_group.new_file(File.join(ROOT, 'GarminDataFieldServiceKitPlugin', 'GarminDataFieldServiceKitPlugin.swift'))]

plugin_target = project.new_target(:framework, 'GarminDataFieldServiceKitPlugin', :ios, IPHONEOS_DEPLOYMENT_TARGET)
plugin_target.build_configurations.each do |config|
  config.build_settings['INFOPLIST_FILE'] = 'GarminDataFieldServiceKitPlugin/Info.plist'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_ID_BASE}Plugin"
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME:c99extidentifier)'
  config.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = ''
  config.build_settings['DYLIB_COMPATIBILITY_VERSION'] = '1'
  config.build_settings['DYLIB_CURRENT_VERSION'] = '1'
  config.build_settings['DYLIB_INSTALL_NAME_BASE'] = '@rpath'
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = '$(inherited)'
  config.build_settings['INSTALL_PATH'] = '$(LOCAL_LIBRARY_DIR)/Frameworks'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
  config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = ''
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['SUPPORTS_MACCATALYST'] = 'NO'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['SWIFT_VERSION'] = SWIFT_VERSION
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['VERSIONING_SYSTEM'] = 'apple-generic'
  config.build_settings['WRAPPER_EXTENSION'] = 'loopplugin'
end

# WRAPPER_EXTENSION only changes what gets built; the product file reference's
# own path must also say .loopplugin so Xcode's UI/build-system references
# (including the scheme's BuildableName) match, exactly as
# NightscoutServiceKitPlugin.loopplugin does in NightscoutService.xcodeproj.
plugin_target.product_reference.path = 'GarminDataFieldServiceKitPlugin.loopplugin'
plugin_target.product_reference.name = 'GarminDataFieldServiceKitPlugin.loopplugin'

plugin_target.add_file_references(plugin_source_files)
plugin_target.frameworks_build_phases.add_file_reference(loopkit_framework_ref, true)
plugin_target.frameworks_build_phases.add_file_reference(loopkitui_framework_ref, true)
plugin_target.add_dependency(kit_target)
plugin_target.add_dependency(kitui_target)
plugin_target.frameworks_build_phases.add_file_reference(kit_target.product_reference, true)
plugin_target.frameworks_build_phases.add_file_reference(kitui_target.product_reference, true)

# Embed Frameworks copy-files phase (dstSubfolderSpec 10 => frameworks)
embed_phase = plugin_target.new_copy_files_build_phase('Embed Frameworks')
embed_phase.dst_subfolder_spec = '10'
embed_phase.dst_path = ''

kit_embed_build_file = embed_phase.add_file_reference(kit_target.product_reference, true)
kit_embed_build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }

kitui_embed_build_file = embed_phase.add_file_reference(kitui_target.product_reference, true)
kitui_embed_build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }

# Move the "Embed Frameworks" phase to run after "Frameworks" the way Xcode
# normally orders things (Headers, Sources, Frameworks, Resources, Embed).
plugin_native_target = plugin_target
phases = plugin_native_target.build_phases
embed_index = phases.index(embed_phase)
if embed_index
  phases.delete_at(embed_index)
  phases << embed_phase
end

# ---------------------------------------------------------------------------
# ConnectIQ SPM package reference + product dependencies
# ---------------------------------------------------------------------------

connectiq_package_ref = project.root_object.package_references.find do |ref|
  ref.is_a?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference) && ref.repositoryURL == CONNECTIQ_PACKAGE_URL
end

if connectiq_package_ref.nil?
  connectiq_package_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  connectiq_package_ref.repositoryURL = CONNECTIQ_PACKAGE_URL
  connectiq_package_ref.requirement = {
    'kind' => 'exactVersion',
    'version' => CONNECTIQ_VERSION
  }
  project.root_object.package_references << connectiq_package_ref
end

def new_connectiq_product_dependency(project, package_ref)
  product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dep.package = package_ref
  product_dep.product_name = 'ConnectIQ'
  product_dep
end

# Package products aren't PBXFileReferences, so PBXBuildFile#file_ref can't be
# used (that's typed to file/group references only); build a PBXBuildFile with
# product_ref set instead, as Xcode itself does for SPM products.
def new_build_file_for_product(project, build_phase, product_dep)
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dep
  build_phase.files << build_file
  build_file
end

def add_connectiq_dependency(project, target, package_ref)
  product_dep = new_connectiq_product_dependency(project, package_ref)
  target.package_product_dependencies << product_dep
  new_build_file_for_product(project, target.frameworks_build_phases, product_dep)
end

# Kit and KitUI link ConnectIQ.
add_connectiq_dependency(project, kit_target, connectiq_package_ref)
add_connectiq_dependency(project, kitui_target, connectiq_package_ref)

# Plugin also links ConnectIQ (needed because GarminDeviceSession.swift and
# GarminDataFieldServiceSettingsView.swift symbols referencing ConnectIQ types
# flow through, and so the embed copy below has something on the link line to
# justify it) via its own package product dependency, matching Kit/KitUI.
plugin_connectiq_product_dep = new_connectiq_product_dependency(project, connectiq_package_ref)
plugin_target.package_product_dependencies << plugin_connectiq_product_dep
new_build_file_for_product(project, plugin_target.frameworks_build_phases, plugin_connectiq_product_dep)

# ConnectIQ ships as a prebuilt binary xcframework, unlike SwiftCharts (a
# source-only SPM package). Its build output lands directly at
# $(BUILT_PRODUCTS_DIR)/ConnectIQ.framework rather than under the
# PackageFrameworks/ subfolder SPM uses for source targets, so - unlike
# Loop's SwiftCharts precedent - it cannot be embedded via a PBXBuildFile
# with product_ref (Xcode cannot resolve that path without having actually
# run package resolution itself, which this generator does not do). Instead
# embed it the same way LoopKit.framework is referenced: a plain
# PBXFileReference with sourceTree BUILT_PRODUCTS_DIR.
connectiq_framework_ref = frameworks_group.new_file('ConnectIQ.framework')
connectiq_framework_ref.source_tree = 'BUILT_PRODUCTS_DIR'
connectiq_framework_ref.include_in_index = nil
connectiq_framework_ref.set_explicit_file_type('wrapper.framework')

connectiq_embed_build_file = embed_phase.add_file_reference(connectiq_framework_ref, true)
connectiq_embed_build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }

# ---------------------------------------------------------------------------
# Reorder targets the way NightscoutService.xcodeproj does (Kit, KitUI, Plugin)
# ---------------------------------------------------------------------------

project.targets.replace([kit_target, kitui_target, plugin_target])

# ---------------------------------------------------------------------------
# Project-level Frameworks group ordering / cleanup
# ---------------------------------------------------------------------------

# xcodeproj's new_file already placed products correctly; nothing further
# needed for the Products group.

project.save

# ---------------------------------------------------------------------------
# Shared scheme
# ---------------------------------------------------------------------------

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(plugin_target)
scheme.set_launch_target(plugin_target)

schemes_dir = File.join(PROJECT_PATH, 'xcshareddata', 'xcschemes')
FileUtils.mkdir_p(schemes_dir)
scheme.save_as(PROJECT_PATH, 'GarminDataFieldServiceKitPlugin', true)

# ---------------------------------------------------------------------------
# Keep the LoopWorkspace shared scheme's BuildActionEntry in sync. The plugin
# target's UUID is regenerated on every run (xcodeproj assigns fresh UUIDs),
# so the sibling workspace scheme that references it by BlueprintIdentifier
# must be patched here rather than hand-maintained.
# ---------------------------------------------------------------------------

workspace_scheme_path = File.expand_path(
  (
    # plugin inside LoopWorkspace (standard layout) or as a sibling of it
    [File.join(ROOT, '..', 'LoopWorkspace.xcworkspace', 'xcshareddata', 'xcschemes', 'LoopWorkspace.xcscheme'),
     File.join(ROOT, '..', 'LoopWorkspace', 'LoopWorkspace.xcworkspace', 'xcshareddata', 'xcschemes', 'LoopWorkspace.xcscheme')].find { |p| File.exist?(p) }
  )
)

if File.exist?(workspace_scheme_path)
  contents = File.read(workspace_scheme_path)
  updated = contents.gsub(
    /(BlueprintIdentifier = ")[0-9A-F]{24}("\s*\n\s*BuildableName = "GarminDataFieldServiceKitPlugin\.loopplugin")/,
    "\\1#{plugin_target.uuid}\\2"
  )
  if updated != contents
    File.write(workspace_scheme_path, updated)
    puts "Patched workspace scheme BlueprintIdentifier -> #{plugin_target.uuid}"
  else
    puts "NOTE: workspace scheme at #{workspace_scheme_path} does not yet contain a GarminDataFieldServiceKitPlugin entry; add it manually with BlueprintIdentifier #{plugin_target.uuid}."
  end
else
  puts "NOTE: workspace scheme not found at #{workspace_scheme_path}; skipping BlueprintIdentifier sync."
end

puts "Generated #{PROJECT_PATH}"
puts "Kit target UUID:    #{kit_target.uuid}"
puts "KitUI target UUID:  #{kitui_target.uuid}"
puts "Plugin target UUID: #{plugin_target.uuid}"
