#!/usr/bin/env python3
"""Deterministic two-target Xcode project; no third-party build tools required."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parents[1]
def uid(s): return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
def q(s): return '"' + s.replace('"', '\\"') + '"'
objects = []
def obj(key, text): objects.append(f'{uid(key)} = {{ {text} }};'); return uid(key)
refs = {}
for folder in ['App', 'Shared', 'Broadcast', 'Fixtures']:
    for p in sorted((root / folder).iterdir()):
        if not p.is_file(): continue
        path = p.relative_to(root).as_posix()
        refs[path] = obj(path, f'isa = PBXFileReference; lastKnownFileType = {"sourcecode.swift" if p.suffix == ".swift" else "file"}; path = {q(path)}; sourceTree = "<group>";')
products = []
for target, suffix, kind in [('ScreenMirror','app','wrapper.application'),('Broadcast','appex','wrapper.app-extension')]:
    products.append(obj(target+'product', f'isa = PBXFileReference; explicitFileType = {kind}; path = {target}.{suffix}; sourceTree = BUILT_PRODUCTS_DIR;'))
products_group = obj('products', f'isa = PBXGroup; children = ({",".join(products)},); name = Products; sourceTree = "<group>";')
group = obj('group', f'isa = PBXGroup; children = ({",".join(list(refs.values()) + [products_group])},); sourceTree = "<group>";')
base = 'SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 16.0; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; CLANG_ENABLE_MODULES = YES;'
def configs(level, settings):
    ids = []
    for mode in ['Debug', 'Release']:
        extra = 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf;' if mode == 'Debug' else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
        ids.append(obj(level+mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ {base} {settings} {extra} }};'))
    return obj(level+'configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(ids)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
configs('project', 'MIRROR_BUNDLE_ID = org.example.ScreenMirror;')
proxy = obj('proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("Broadcasttarget")}; remoteInfo = Broadcast;')
dependency = obj('dependency', f'isa = PBXTargetDependency; target = {uid("Broadcasttarget")}; targetProxy = {proxy};')
embed_file = obj('embedfile', f'isa = PBXBuildFile; fileRef = {products[1]}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
embed = obj('embed', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({embed_file},); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
for index, target in enumerate(['ScreenMirror', 'Broadcast']):
    app = index == 0
    sources, resources = [], []
    for path, ref in refs.items():
        include = path.startswith(('App/', 'Shared/', 'Fixtures/')) if app else (path.startswith(('Broadcast/', 'Shared/')) or path in ['App/UPnP.swift', 'App/HTTPServer.swift'])
        if not include: continue
        build = obj(target+path, f'isa = PBXBuildFile; fileRef = {ref};')
        (sources if path.endswith('.swift') else resources).append(build)
    phases = []
    for kind, files in [('Sources', sources), ('Resources', resources), ('Frameworks', [])]:
        phases.append(obj(target+kind, f'isa = PBX{kind}BuildPhase; buildActionMask = 2147483647; files = ({",".join(files)}{"," if files else ""}); runOnlyForDeploymentPostprocessing = 0;'))
    if app: phases.append(embed)
    bundle = '$(MIRROR_BUNDLE_ID)' + ('' if app else '.Broadcast')
    plist = 'Config/Info.plist' if app else 'Config/Broadcast-Info.plist'
    settings = f'PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "{bundle}"; CODE_SIGN_STYLE = Automatic; CODE_SIGN_ENTITLEMENTS = Config/Manual.entitlements; INFOPLIST_FILE = {plist}; GENERATE_INFOPLIST_FILE = NO; CURRENT_PROJECT_VERSION = 9; MARKETING_VERSION = 0.5.1;'
    if not app: settings += ' APPLICATION_EXTENSION_API_ONLY = YES; SKIP_INSTALL = YES;'
    config_list = configs(target, settings)
    obj(target+'target', f'isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = ({",".join(phases)},); buildRules = (); dependencies = ({dependency + "," if app else ""}); name = {target}; productName = {target}; productReference = {products[index]}; productType = "com.apple.product-type.{"application" if app else "app-extension"}";')
project = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ru; knownRegions = (ru,en,Base); mainGroup = {group}; productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = ({uid("ScreenMirrortarget")},{uid("Broadcasttarget")},);')
out = root / 'ScreenMirror.xcodeproj'; out.mkdir(exist_ok=True)
(out / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {project}; }}\n')
schemes = out / 'xcshareddata/xcschemes'; schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'ScreenMirror.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('ScreenMirrortarget')}" BuildableName="ScreenMirror.app" BlueprintName="ScreenMirror" ReferencedContainer="container:ScreenMirror.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('ScreenMirrortarget')}" BuildableName="ScreenMirror.app" BlueprintName="ScreenMirror" ReferencedContainer="container:ScreenMirror.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>
''')
print(out)
