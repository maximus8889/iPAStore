"""Verify the packaged development candidate without treating ad-hoc signing as provisioning."""
from pathlib import Path
import argparse,hashlib,json,plistlib,struct,subprocess,zipfile
p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--ipa',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.add_argument('--expected-build');args=p.parse_args()
app=args.app;info=plistlib.loads((app/'Info.plist').read_bytes());assert info['CFBundleIdentifier']=='app.ipastore.IPAStore'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
for bundle in [app,*sorted((app/'PlugIns').glob('*.appex'))]:
 value=plistlib.loads((bundle/'Info.plist').read_bytes());assert value['CFBundleVersion']==info['CFBundleVersion'];assert (bundle/value['CFBundleExecutable']).exists()
 if bundle==app or bundle.name=='LiveProcess.appex':
  ent=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(bundle)],stderr=subprocess.DEVNULL));groups=ent['keychain-access-groups'];expected=['UNSIGNED00.com.kdt.livecontainer.shared']+['UNSIGNED00.com.kdt.livecontainer.shared.'+str(i) for i in range(1,128)];assert set(expected)<=set(groups)
assert not list(app.rglob('embedded.mobileprovision'))
assert info['CFBundleDisplayName']=='iPAStore'
if args.expected_build: assert info['CFBundleVersion']==args.expected_build
for resource in ['LibraryDirectory.json','Monocraft.ttf','Monocraft-LICENSE.txt','iOSHub-LICENSE.txt','OpenSourceNotices.txt']: assert (app/resource).is_file(), resource
registry=json.loads((app/'LibraryDirectory.json').read_text());assert len(registry['libraries'])==87
selectable_icons = {'AppIconLight', 'AppIconMidnight', 'AppIconOcean', 'AppIconJade', 'AppIconIris', 'AppIconEmber', 'AppIconSand', 'AppIconRose'}
for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
    alternates = info[key]['CFBundleAlternateIcons']
    assert selectable_icons <= set(alternates)
    for name in selectable_icons:
        files = alternates[name]['CFBundleIconFiles']
        assert files and all(any(app.glob(base + '@*.png')) for base in files), (key, name)
service=app/'Frameworks/SideStoreApp.framework';v=plistlib.loads((service/'Info.plist').read_bytes());data=(service/v['CFBundleExecutable']).read_bytes();assert struct.unpack_from('<I',data,12)[0]==6
for marker in [b'IPAStoreSigningController',b'startTaskWithRequest:progress:completion:',b'startRefreshWithProgress:completion:']:assert marker in data
with zipfile.ZipFile(args.ipa) as z:assert z.testzip() is None
report={'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'sha256':hashlib.sha256(args.ipa.read_bytes()).hexdigest(),'archive_crc':'PASS','deep_strict_signature':'PASS','keychain_groups':128,'profile':'No real account provisioning embedded','native_worker':'Matching renewal and installation selectors present','extensions':'Version aligned with host','guest_execution':'UNTESTED','renewal_cycle':'UNTESTED'}
args.report.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
