"""Build a content-free iOS host on macOS. No game input is used here."""
from pathlib import Path
import subprocess, plistlib, json, shutil, hashlib, zipfile, tarfile, urllib.request, os

root=Path(__file__).resolve().parents[2]
out=root/'output'
app=out/'Rhythm3DS.app'
app.mkdir(parents=True,exist_ok=True)

# Public, pinned iOS graphics runtime. No game files are involved in this
# download/build. Verify the release's published SHA256 before extraction.
dependency=root/'build/deps/MoltenVK-ios-v1.4.2.tar'
dependency.parent.mkdir(parents=True,exist_ok=True)
dependency_sha='b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1'
if not dependency.exists():
    urllib.request.urlretrieve('https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-ios.tar',dependency)
assert hashlib.file_digest(dependency.open('rb'),'sha256').hexdigest()==dependency_sha
metal=app/'Frameworks/MoltenVK.framework';metal.mkdir(parents=True,exist_ok=True)
prefix='MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/'
with tarfile.open(dependency) as archive:
    for name in ['MoltenVK','Info.plist']:
        with archive.extractfile(prefix+name) as source,(metal/name).open('wb') as target:
            shutil.copyfileobj(source,target)
    vendor_license=archive.extractfile('MoltenVK/LICENSE').read()
os.chmod(metal/'MoltenVK',0o755)
def run(args,**kwargs):
    subprocess.run([str(a) for a in args],check=True,**kwargs)
sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
run(['cargo','build','--locked','--release','--manifest-path',root/'source/mobile-bridge/Cargo.toml',
     '--target','aarch64-apple-ios','--target-dir',root/'build/mobile','-j','3'])
library=root/'build/mobile/aarch64-apple-ios/release/librh3ds_mobile.a'
run(['xcrun','--sdk','iphoneos','clang','-arch','arm64','-isysroot',sdk,'-miphoneos-version-min=16.0',
     '-O2','-fobjc-arc','-fmodules','-Werror=implicit-function-declaration',root/'source/ios-host/Main.m',
     library,'-framework','UIKit','-framework','Foundation','-framework','AVFoundation',
     '-framework','AudioToolbox','-framework','QuartzCore','-framework','CoreFoundation',
     '-framework','Security','-framework','CoreGraphics','-framework','GameController','-lSystem','-lresolv','-liconv','-lz',
     '-Wl,-dead_strip','-Wl,-rpath,@executable_path/Frameworks','-o',app/'Rhythm3DS'])
plist=dict(CFBundleExecutable='Rhythm3DS',CFBundleIdentifier='org.rhythmheaven.3ds.experimental',
    CFBundleName='Rhythm3DS',CFBundleDisplayName='节奏天国3DS',CFBundlePackageType='APPL',
    CFBundleShortVersionString='1.0.0',CFBundleVersion='2026102301',MinimumOSVersion='16.0',
    GCSupportsControllerUserInteraction=True,GCSupportedGameControllers=[dict(ProfileName='ExtendedGamepad')],
    CFBundleSupportedPlatforms=['iPhoneOS'],UIDeviceFamily=[1,2],UIRequiresFullScreen=True,
    UIFileSharingEnabled=True,LSSupportsOpeningDocumentsInPlace=True,UILaunchScreen={},
    UIUserInterfaceStyle='Dark',UISupportedInterfaceOrientations=['UIInterfaceOrientationLandscapeLeft',
    'UIInterfaceOrientationLandscapeRight','UIInterfaceOrientationPortrait'])
(app/'Info.plist').write_bytes(plistlib.dumps(plist))
licenses=app/'Licenses';licenses.mkdir(exist_ok=True)
(licenses/'MoltenVK-LICENSE.txt').write_bytes(vendor_license)
for name in ['zakuro','3dsrecomp']:
    for candidate in [root/'source'/name/'LICENSE',root/'source'/name/'LICENSE.md']:
        if candidate.exists():shutil.copyfile(candidate,licenses/(name+'-LICENSE.txt'));break
shutil.copy2(root/'LICENSES/3dsrecomp-NOTICE.txt',licenses/'3dsrecomp-NOTICE.txt')
shutil.copy2(root/'LICENSE',licenses/'project-MIT.txt')
(licenses/'EXPERIMENT.txt').write_text('Experimental 3DS compatibility runtime. CPU AOT with interpreter fallback.\nCPU shader JIT disabled. Metal through MoltenVK is attempted, with software recovery.\nGame content is supplied locally.\n')
run(['codesign','--force','--sign','-',metal])
run(['codesign','--force','--sign','-',app])
files=[p for p in app.rglob('*') if p.is_file()]
assert not (app/'Game').exists() and not (app/'Frameworks/Guest.framework').exists() and not (app/'Fonts').exists()
report=dict(content_free=True,game_uploaded=False,sdk=sdk,graphics_dependency=dict(name='MoltenVK',version='1.4.2',archive_sha256=dependency_sha,license='Apache-2.0'),files=[dict(path=p.relative_to(app).as_posix(),bytes=p.stat().st_size,
    sha256=hashlib.file_digest(p.open('rb'),'sha256').hexdigest()) for p in files])
(out/'host_manifest.json').write_text(json.dumps(report,indent=2)+'\n')
with zipfile.ZipFile(out/'rh3ds-host-only.zip','w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in files:z.write(p,'Payload/'+p.relative_to(out).as_posix())
# An IPA is a ZIP with a Payload directory. Audit this exact archive before release.
shutil.copy2(out/'rh3ds-host-only.zip',out/'RhythmHeaven3DS-shell.ipa')
print('Built content-free shell IPA; prepare game content locally.')
