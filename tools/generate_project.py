#!/usr/bin/env python3
"""Deterministic, dependency-free Xcode project/resource generator. Run from anywhere."""
from pathlib import Path
import hashlib
import json
import plistlib
try:
    from .validate_assets import validate_alarm_sounds
except ImportError:
    from validate_assets import validate_alarm_sounds

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ['en','zh-Hant','zh-Hans','yue','ja','ko','es','fr','de','it','pt-BR','ru','ar','id','th','vi','tr','hi','pl','nl']

def uid(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def write(path, data):
    path = ROOT / path
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, bytes):
        path.write_bytes(data)
    else:
        path.write_text(data, encoding='utf-8')

def load_translations():
    translations = json.loads((ROOT / 'Resources/translations.json').read_text())
    for path in sorted((ROOT/'Resources/Translations').glob('*.json')):
        values = json.loads(path.read_text())
        base = values.pop('_base',None)
        translations[path.stem] = {**translations.get(base,{}),**values}
    english = translations['en']
    # Text translation files are ordered records. Fail if a source-key reorder
    # would silently assign a valid translation to the wrong key. Update this
    # fingerprint only together with a reviewed reorder of every .txt file.
    key_order = hashlib.sha256('\n'.join(english).encode()).hexdigest()
    if key_order != '3692ebad54717409a8013b59555ff4002617d72fa1222fa4a9abbde7f1815a28':
        raise ValueError('Translation key order changed; migrate all ordered language files before updating the fingerprint')
    for path in sorted((ROOT/'Resources/Translations').glob('*.txt')):
        values = path.read_text().splitlines()
        if len(values) > len(english): raise ValueError(f'{path.name}: {len(values)} rows, expected at most {len(english)}')
        # Newly added strings fall back to reviewed English until a translator
        # supplies the corresponding trailing row. Existing row order remains
        # protected by the fingerprint above.
        translations[path.stem] = {**english, **dict(zip(english,values))}
    return translations

def generate_resources():
    translations = load_translations()
    english = translations['en']
    for language in LANGUAGES:
        values = {**english, **translations[language]}
        if set(values) != set(english): raise ValueError(f'{language}: translation keys differ from English')
        def escaped(s): return json.dumps(s, ensure_ascii=False)
        contents = '\n'.join(f'{escaped(key)} = {escaped(values[key])};' for key in english) + '\n'
        write(f'Resources/{language}.lproj/Localizable.strings', contents)
        info = '\n'.join(f'{escaped(key)} = {escaped(values.get(source, english[source]))};' for key, source in [
            ('NSCameraUsageDescription','permission.camera.description'),
            ('NSAlarmKitUsageDescription','permission.alarm.description')]) + '\n'
        write(f'Resources/{language}.lproj/InfoPlist.strings', info)
    # Alarm audio is a reviewed, licensed product asset. Never synthesize or
    # overwrite it when regenerating the project; doing so could silently put
    # an obsolete sound back into a release build.
    validate_alarm_sounds()
    write('Resources/Assets.xcassets/Contents.json', json.dumps({'info':{'author':'xcode','version':1}}))
    write('Resources/Assets.xcassets/AccentColor.colorset/Contents.json', json.dumps({'info':{'author':'xcode','version':1},'colors':[{'idiom':'universal','color':{'color-space':'srgb','components':{'red':'0.97','green':'0.43','blue':'0.20','alpha':'1.0'}}}]}))

def generate_project():
    objects = {}
    def obj(label, **fields):
        key = uid(label); objects[key] = fields; return key
    def ref(path, filetype=None, **extra):
        ext = Path(path).suffix
        types = {'.swift':'sourcecode.swift','.json':'text.json','.wav':'audio.wav','.xcassets':'folder.assetcatalog','.xcconfig':'text.xcconfig','.plist':'text.plist.xml','.entitlements':'text.plist.entitlements'}
        return obj('file:'+path, isa='PBXFileReference', lastKnownFileType=filetype or types.get(ext,'text'), path=path, sourceTree='SOURCE_ROOT', **extra)
    local = obj('package', isa='XCLocalSwiftPackageReference', relativePath='.')
    variants = []
    for basename in ['Localizable.strings','InfoPlist.strings']:
        children = [ref(f'Resources/{lang}.lproj/{basename}', 'text.plist.strings', name=lang) for lang in LANGUAGES]
        variants.append(obj('variant:'+basename, isa='PBXVariantGroup', name=basename, children=children, sourceTree='<group>'))
    shared = [str(p.relative_to(ROOT)) for p in sorted((ROOT/'Shared').glob('*.swift'))]
    sources = {'Okiru': [str(p.relative_to(ROOT)) for p in sorted((ROOT/'App').rglob('*.swift'))]+shared,
               'OkiruMonitor':['Extensions/Monitor/MonitorExtension.swift']+shared,
               'OkiruShield':['Extensions/Shield/ShieldExtension.swift']+shared,
               'OkiruShieldAction':['Extensions/ShieldAction/ShieldActionExtension.swift']+shared}
    phases = {}; targets = {}; products = {}; configs = {}
    config_ref = ref('Config/Project.xcconfig')
    for name, files in sources.items():
        is_app = name == 'Okiru'
        products[name] = obj('product:'+name, isa='PBXFileReference', explicitFileType='wrapper.application' if is_app else 'wrapper.app-extension', path=name+('.app' if is_app else '.appex'), sourceTree='BUILT_PRODUCTS_DIR')
        dep = obj('packageproduct:'+name, isa='XCSwiftPackageProductDependency', package=local, productName='OkiruCore')
        framework = obj('framework:'+name, isa='PBXBuildFile', productRef=dep)
        build_files = [obj(name+':source:'+p, isa='PBXBuildFile', fileRef=ref(p)) for p in files]
        resources = variants[:]
        if is_app:
            resources += [ref('Resources/Assets.xcassets'),ref('Config/Services.json')]
            resources += [ref(str(p.relative_to(ROOT))) for p in sorted((ROOT/'Resources/Sounds').glob('*.wav'))]
            resources += [ref('Resources/PrivacyInfo.xcprivacy','text.xml')]
        resource_files = [obj(name+':resource:'+p, isa='PBXBuildFile', fileRef=p) for p in resources]
        phase_ids = [obj('sources:'+name, isa='PBXSourcesBuildPhase', buildActionMask=2147483647, files=build_files, runOnlyForDeploymentPostprocessing=0),
                     obj('frameworks:'+name, isa='PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[framework], runOnlyForDeploymentPostprocessing=0),
                     obj('resources:'+name, isa='PBXResourcesBuildPhase', buildActionMask=2147483647, files=resource_files, runOnlyForDeploymentPostprocessing=0)]
        configs[name] = []
        for mode in ['Debug','Release']:
            settings = {'PRODUCT_NAME':name, 'PRODUCT_BUNDLE_IDENTIFIER':'$(OKIRU_BUNDLE_PREFIX)'+('' if is_app else '.'+name),
                        'INFOPLIST_FILE':f'Config/{name}-Info.plist','CODE_SIGN_ENTITLEMENTS':f'Config/{name}.entitlements',
                        'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O',
                        'ONLY_ACTIVE_ARCH':'YES' if mode=='Debug' else 'NO',
                        'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else '',
                        'SKIP_INSTALL':'NO' if is_app else 'YES', 'APPLICATION_EXTENSION_API_ONLY':'NO' if is_app else 'YES',
                        'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'+('' if is_app else ' @executable_path/../../Frameworks')}
            if is_app: settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME']='AccentColor'
            if is_app and (ROOT/'Resources/Assets.xcassets/AppIcon.appiconset').exists(): settings['ASSETCATALOG_COMPILER_APPICON_NAME']='AppIcon'
            configs[name].append(obj(name+':config:'+mode, isa='XCBuildConfiguration', baseConfigurationReference=config_ref, buildSettings=settings, name=mode))
        configlist = obj('configlist:'+name, isa='XCConfigurationList', buildConfigurations=configs[name], defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
        targets[name] = obj('target:'+name, isa='PBXNativeTarget', buildConfigurationList=configlist, buildPhases=phase_ids, buildRules=[], dependencies=[], name=name, productName=name, productReference=products[name], productType='com.apple.product-type.application' if is_app else 'com.apple.product-type.app-extension', packageProductDependencies=[dep])
        info = {'CFBundleDevelopmentRegion':'en','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)',
                'CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'Okiru' if is_app else name,'CFBundlePackageType':'APPL' if is_app else 'XPC!',
                'CFBundleShortVersionString':'1.0.0','CFBundleVersion':'18','OkiruAppGroup':'$(OKIRU_APP_GROUP)'}
        if is_app:
            info.update({'LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False},
                         'ITSAppUsesNonExemptEncryption':False,
                         'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],
                         'NSCameraUsageDescription':'Okiru uses the front camera to count push-ups on this device. No video is stored or uploaded.',
                         'NSAlarmKitUsageDescription':'Okiru schedules your wake-up alarms.',
                         'CFBundleURLTypes':[{'CFBundleURLName':'okiru','CFBundleURLSchemes':['okiru']}]})
        else:
            point, cls = {'OkiruMonitor':('com.apple.deviceactivity.monitor-extension','MonitorExtension'),
                          'OkiruShield':('com.apple.ManagedSettingsUI.shield-configuration-service','ShieldExtension'),
                          'OkiruShieldAction':('com.apple.ManagedSettings.shield-action-service','ShieldActionExtension')}[name]
            info['CFBundleDisplayName'] = {'OkiruMonitor':'Okiru Monitor','OkiruShield':'Okiru Shield','OkiruShieldAction':'Okiru Shield Action'}[name]
            info['NSExtension']={'NSExtensionPointIdentifier':point,'NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).'+cls}
        write(f'Config/{name}-Info.plist', plistlib.dumps(info))
        write(f'Config/{name}.entitlements', plistlib.dumps({'com.apple.developer.family-controls':True,'com.apple.security.application-groups':['$(OKIRU_APP_GROUP)']}))
    embeds = []
    for name in list(sources)[1:]:
        embeds.append(obj('embed:'+name, isa='PBXBuildFile', fileRef=products[name], settings={'ATTRIBUTES':['RemoveHeadersOnCopy']}))
        proxy = obj('proxy:'+name, isa='PBXContainerItemProxy', containerPortal=uid('project'), proxyType=1, remoteGlobalIDString=targets[name], remoteInfo=name)
        dependency = obj('dependency:'+name, isa='PBXTargetDependency', target=targets[name], targetProxy=proxy)
        objects[targets['Okiru']]['dependencies'].append(dependency)
    embedphase = obj('embedphase', isa='PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=13, files=embeds, name='Embed App Extensions', runOnlyForDeploymentPostprocessing=0)
    objects[targets['Okiru']]['buildPhases'].append(embedphase)
    test_files = [str(p.relative_to(ROOT)) for p in sorted((ROOT/'UITests').glob('*.swift'))]
    test_product = obj('product:OkiruUITests',isa='PBXFileReference',explicitFileType='wrapper.cfbundle',path='OkiruUITests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
    products['OkiruUITests'] = test_product
    test_sources = obj('sources:OkiruUITests',isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=[obj('test:'+p,isa='PBXBuildFile',fileRef=ref(p)) for p in test_files],runOnlyForDeploymentPostprocessing=0)
    test_configs = [obj('tests:'+mode,isa='XCBuildConfiguration',baseConfigurationReference=config_ref,buildSettings={'PRODUCT_NAME':'OkiruUITests','PRODUCT_BUNDLE_IDENTIFIER':'$(OKIRU_BUNDLE_PREFIX).uitests','GENERATE_INFOPLIST_FILE':'YES','TEST_TARGET_NAME':'Okiru','SWIFT_OPTIMIZATION_LEVEL':'-Onone','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'},name=mode) for mode in ['Debug','Release']]
    test_configlist = obj('configlist:tests',isa='XCConfigurationList',buildConfigurations=test_configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Debug')
    test_proxy = obj('proxy:testapp',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=targets['Okiru'],remoteInfo='Okiru')
    test_dep = obj('dependency:testapp',isa='PBXTargetDependency',target=targets['Okiru'],targetProxy=test_proxy)
    targets['OkiruUITests'] = obj('target:OkiruUITests',isa='PBXNativeTarget',buildConfigurationList=test_configlist,buildPhases=[test_sources],buildRules=[],dependencies=[test_dep],name='OkiruUITests',productName='OkiruUITests',productReference=test_product,productType='com.apple.product-type.bundle.ui-testing')
    group_products = obj('products', isa='PBXGroup', children=list(products.values()), name='Products', sourceTree='<group>')
    visible = [k for k,v in objects.items() if v['isa']=='PBXFileReference' and k not in products.values() and not v.get('name')]
    main = obj('main', isa='PBXGroup', children=visible+variants+[group_products], sourceTree='<group>')
    project_configs = [obj('projectconfig:'+mode, isa='XCBuildConfiguration', buildSettings={'CLANG_ENABLE_MODULES':'YES','SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'targeted'}, name=mode) for mode in ['Debug','Release']]
    plist = obj('projectconfigs', isa='XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
    project = obj('project', isa='PBXProject', attributes={'LastUpgradeCheck':'2700','BuildIndependentTargetsInParallel':'YES'}, buildConfigurationList=plist,
                  compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=LANGUAGES,
                  mainGroup=main, productRefGroup=group_products, projectDirPath='', projectRoot='', targets=list(targets.values()), packageReferences=[local])
    def encode(value, indent=0):
        if isinstance(value, dict): return '{\n'+''.join('\t'*(indent+1)+json.dumps(k)+' = '+encode(v,indent+1)+';\n' for k,v in value.items())+'\t'*indent+'}'
        if isinstance(value, list): return '('+', '.join(encode(v,indent) for v in value)+')'
        return str(value) if isinstance(value,int) else json.dumps(value)
    write('Okiru.xcodeproj/project.pbxproj','// !$*UTF8*$!\n'+encode({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
    target = targets['Okiru']
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Okiru.app" BlueprintName="Okiru" ReferencedContainer="container:Okiru.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets['OkiruUITests']}" BuildableName="OkiruUITests.xctest" BlueprintName="OkiruUITests" ReferencedContainer="container:Okiru.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Okiru.app" BlueprintName="Okiru" ReferencedContainer="container:Okiru.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
    write('Okiru.xcodeproj/xcshareddata/xcschemes/Okiru.xcscheme',scheme)

if __name__ == '__main__':
    generate_resources()
    generate_project()
    print('Generated Okiru.xcodeproj and 20 localization bundles; preserved reviewed alarm sounds.')
