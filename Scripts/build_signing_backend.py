"""Reconstruct IPAStore's private signing derivative from its corresponding source.
Requires Xcode and the pinned Swift package sources (network may be needed on first build).
Does not configure credentials, provision, revoke certificates, or publish anything.
"""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess, tarfile
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--work', required=True, type=Path, help='New, private build directory')
args = p.parse_args()
work = args.work.resolve()
if work.exists(): raise FileExistsError('Choose a new work directory; existing source is never overwritten')
manifest = json.loads((root/'ThirdParty/signing-source-manifest.json').read_text())
archive = root/'ThirdParty/signing-service-corresponding-source.tar.gz'
assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['source_archive_sha256']
work.mkdir(parents=True)
with tarfile.open(archive) as source:
    # Python's data filter rejects external/traversing paths and unsafe link targets.
    source.extractall(work, filter='data')
backend = work/'SideStore'
for patch in ['WidgetAppearance.patch', 'AccountSignInCompatibility.patch']:
    subprocess.run(['patch', '--batch', '--forward', '-p1', '-i',
                    str(root/'SigningBackend'/patch)], cwd=backend, check=True)
addition = backend/'SideStore/IPAStore'
addition.mkdir(parents=True, exist_ok=True)
for source, name in [(root/'SigningBackend/IPAStoreNativeSigning.swift','IPAStoreNativeSigning.swift'), (root/'SideStoreSupport/IPAResultGate.swift','IPAResultGate.swift')]:
    shutil.copy2(source, addition/name)
for name in ['AuthenticationViewController.swift','Authentication.storyboard']:
    shutil.copy2(root/'SigningBackend/Authentication'/name, backend/'AltStore/Authentication'/name)
shutil.copy2(root/'ThirdParty/Signing-Package.resolved', backend/'AltStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
subprocess.run(['xcodebuild','-project',str(backend/'AltStore.xcodeproj'),'-scheme','SideStore','-sdk','iphoneos','-configuration','Release','-destination','generic/platform=iOS','-derivedDataPath',str(work/'Build'),'-clonedSourcePackagesDirPath',str(work/'Packages'),'-onlyUsePackageVersionsFromResolvedFile','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','DEVELOPMENT_TEAM=XYZ0123456','ORG_IDENTIFIER=com.SideStore','build'], check=True)
print(work/'Build/Build/Products/Release-iphoneos/SideStore.app')
