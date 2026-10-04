#!/usr/bin/env python3
"""Generate the small native Xcode project with no third-party build dependency."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1]
project = root / 'PhotosDuplicateClean.xcodeproj'
project.mkdir(exist_ok=True)
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return '"' + str(s).replace('"', '\\"') + '"'
objects = []
def add(name, body): objects.append(f'{uid(name)} = {{ {body} }};'); return uid(name)
sources = sorted(root.glob('Sources/**/*.swift'))
files, builds = [], []
for p in sources:
    path = p.relative_to(root).as_posix()
    fid = add(path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path)}; sourceTree = "<group>";')
    files.append(fid)
    builds.append(add('build:'+path, f'isa = PBXBuildFile; fileRef = {fid};'))
asset_path = 'Assets/Assets.xcassets'
asset_id = add(asset_path, f'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {q(asset_path)}; sourceTree = "<group>";')
files.append(asset_id)
asset_build = add('build:'+asset_path, f'isa = PBXBuildFile; fileRef = {asset_id};')
resources = add('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({asset_build},); runOnlyForDeploymentPostprocessing = 0;')
app = add('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = WorthPhotos.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = add('products', f'isa = PBXGroup; children = ({app},); name = Products; sourceTree = "<group>";')
main = add('main', f'isa = PBXGroup; children = ({",".join(files+[products])},); sourceTree = "<group>";')
phase = add('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
frameworks = add('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
common = {'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'15.0','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','ARCHS':'arm64','SUPPORTED_PLATFORMS':'macosx'}
target = dict(common, PRODUCT_NAME='WorthPhotos',PRODUCT_BUNDLE_IDENTIFIER='app.local.TravelSelect', INFOPLIST_FILE='Configuration/Info.plist', GENERATE_INFOPLIST_FILE='NO', CODE_SIGN_ENTITLEMENTS='Configuration/TravelSelect.entitlements', CODE_SIGN_IDENTITY='-', CODE_SIGN_STYLE='Manual', ENABLE_HARDENED_RUNTIME='YES', ENABLE_APP_SANDBOX='YES', SWIFT_EMIT_LOC_STRINGS='NO', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME='AccentColor')
def configs(name, settings):
    ids=[]
    for mode in ('Debug','Release'):
        config=dict(settings, SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if mode=='Debug' else '', SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode=='Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf', ENABLE_TESTABILITY='YES' if mode=='Debug' else 'NO')
        ids.append(add(name+mode,'isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {'+' '.join(k+' = '+q(v)+';' for k,v in config.items())+'};'))
    return add(name+'list',f'isa = XCConfigurationList; buildConfigurations = ({",".join(ids)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
pc=configs('project',common); tc=configs('target',target)
tid=add('target',f'isa = PBXNativeTarget; buildConfigurationList = {tc}; buildPhases = ({phase},{frameworks},{resources},); buildRules = (); dependencies = (); name = TravelSelect; productName = WorthPhotos; productReference = {app}; productType = "com.apple.product-type.application";')
pid=add('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; knownRegions = (zh_CN,en,Base,); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({tid},);')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {pid}; }}\n')
scheme=project/'xcshareddata/xcschemes/TravelSelect.xcscheme'
scheme.parent.mkdir(parents=True,exist_ok=True)
reference=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{tid}" BuildableName="WorthPhotos.app" BlueprintName="TravelSelect" ReferencedContainer="container:PhotosDuplicateClean.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('PhotosDuplicateClean.xcodeproj generated')
