#!/usr/bin/env python3
"""Package the actual iphoneos build, retaining the required ReplayKit extension."""
from pathlib import Path
import plistlib, subprocess,zipfile
root=Path(__file__).resolve().parents[1]
app=root/'build/DerivedData/Build/Products/Release-iphoneos/ScreenMirror.app'
assert app.is_dir(), 'Real iPhone app build missing. A simulator app cannot be installed on iPhone.'
info=plistlib.loads((app/'Info.plist').read_bytes())
assert info.get('DTPlatformName')=='iphoneos', 'Wrong build platform'
ext=app/'PlugIns/Broadcast.appex'
extinfo=plistlib.loads((ext/'Info.plist').read_bytes())
assert extinfo['CFBundleIdentifier']==info['CFBundleIdentifier']+'.Broadcast', 'App/extension IDs disagree'
assert extinfo['NSExtension']['NSExtensionPointIdentifier']=='com.apple.broadcast-services-upload'
for bundle, meta in [(app,info),(ext,extinfo)]:
    binary=bundle/meta['CFBundleExecutable']
    archs=subprocess.check_output(['xcrun','lipo','-archs',str(binary)],text=True)
    assert 'arm64' in archs.split(), (binary,archs)
out=root/'build/ScreenMirror-unsigned.ipa'
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as archive:
    for path in app.rglob('*'):
        if path.is_file(): archive.write(path,Path('Payload/ScreenMirror.app')/path.relative_to(app))
with zipfile.ZipFile(out) as archive:
    assert 'Payload/ScreenMirror.app/PlugIns/Broadcast.appex/Info.plist' in archive.namelist()
    assert archive.testzip() is None
print('Created unsigned device IPA with Broadcast extension:',out)
print('This IPA must be signed locally before installation.')
