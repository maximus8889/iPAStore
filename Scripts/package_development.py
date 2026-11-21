"""Package local source builds; never downloads a mutable nightly IPA.
All editing happens in a fresh staging directory. Output needs real development signing.
"""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, shutil, stat, struct, subprocess, tempfile, zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--engine', required=True, type=Path)
parser.add_argument('--service', required=True, type=Path)
parser.add_argument('--dylibify', required=True, type=Path)
parser.add_argument('--widget', type=Path)
parser.add_argument('--staging-parent', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
if args.output.exists(): raise FileExistsError('Use a new output name instead of overwriting a build')
root = Path(__file__).resolve().parents[1]
args.staging_parent.mkdir(parents=True, exist_ok=True)
stage = Path(tempfile.mkdtemp(prefix='ipastore-package-', dir=args.staging_parent))
app = stage / 'Payload' / 'IPAStore.app'
shutil.copytree(args.engine, app, symlinks=True)
service = app / 'Frameworks' / 'SideStoreApp.framework'
shutil.copytree(args.service, service, symlinks=True)


def read_plist(path): return plistlib.loads(path.read_bytes())
def write_plist(path, value): path.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=False))

info_path = app / 'Info.plist'
info = read_plist(info_path)
assert info['CFBundleIdentifier'] == 'app.ipastore.IPAStore', 'Build the distinct IPAStore identity before packaging'
info['CFBundleDisplayName'] = 'iPAStore'
info['ALTAppGroups'] = ['group.com.SideStore.SideStore']
info['INIntentsSupported'] = ['RefreshAllIntent', 'ViewAppIntent']
info['NSUserActivityTypes'] = ['RefreshAllIntent', 'ViewAppIntent']

# Some Xcode versions emit asset names without icon files for alternate icon
# appearances. Include the named PNG renditions so iOS can resolve the icons
# when a sideloaded bundle has been re-signed.
for device_key, suffix, renditions in [
    ('CFBundleIcons', '', [(60, 2), (60, 3)]),
    ('CFBundleIcons~ipad', '~ipad', [(76, 2), (83.5, 2)]),
]:
    for name, icon in info.get(device_key, {}).get('CFBundleAlternateIcons', {}).items():
        if icon.get('CFBundleIconFiles'):
            continue
        assets = root / 'Resources' / 'Assets.xcassets' / (name + '.appiconset')
        source = assets / next(entry['filename'] for entry in json.loads((assets / 'Contents.json').read_text())['images']
                               if entry.get('filename') and not entry.get('appearances'))
        files = []
        for points, scale in renditions:
            base = f'{name}{points}x{points}'
            target = app / f'{base}@{scale}x{suffix}.png'
            pixels = str(int(points * scale))
            subprocess.run(['sips', '-z', pixels, pixels, str(source), '--out', str(target)],
                           stdout=subprocess.DEVNULL, check=True)
            files.append(base)
        icon['CFBundleIconFiles'] = files
# Keep the host's unique launch scheme; the private service URL is passed internally.
write_plist(info_path, info)
# Separate native icon artwork for the signing setup, whose compiled asset catalog
# remains part of the pinned backend. The host integration selects appearance.
shutil.copy2(root / 'Resources/Assets.xcassets/AppIcon.appiconset/IPAStore-Light.png', app / 'IPAStoreSigningIconLight.png')
shutil.copy2(root / 'Resources/Assets.xcassets/AppIcon.appiconset/IPAStore-Black.png', app / 'IPAStoreSigningIconDark.png')

shutil.copy2(root / 'Resources/Success.wav', service / 'Success.wav')

service_info_path = service / 'Info.plist'
service_info = read_plist(service_info_path)
service_info['CFBundleDisplayName'] = 'iPAStore Signing'
write_plist(service_info_path, service_info)
service_exec = service / service_info['CFBundleExecutable']
subprocess.run(['python3', str(root / 'Scripts/update_signing_symbol.py'), str(service_exec)], check=True)
service_bytes = service_exec.read_bytes()
for marker in [b'IPAStoreSigningController', b'controllerWithAppearance:returnHandler:', b'startRefreshWithProgress:completion:', b'startTaskWithRequest:progress:completion:']:
    assert marker in service_bytes, 'Signing service is missing the matching IPAStore native bridge'
header = service_bytes[:32]
assert len(header) == 32 and struct.unpack_from('<I', header)[0] == 0xfeedfacf
if struct.unpack_from('<I', header, 12)[0] != 6:
    patched = stage / 'signing-service.dylib'
    subprocess.run([str(args.dylibify.resolve()), str(service_exec), str(patched)], check=True)
    header = patched.read_bytes()[:32]
    assert struct.unpack_from('<I', header, 12)[0] == 6, 'Service conversion did not produce MH_DYLIB'
    shutil.copy2(patched, service_exec)
shutil.copy2(root / '.github/sidelc/LCAppInfo.plist', service / 'LCAppInfo.plist')

# Match the host's existing intent bridge to the service built from the pinned sources.
for name in ['Intents.intentdefinition', 'ViewApp.intentdefinition']:
    original = service / name
    if original.exists(): shutil.copy2(original, app / name)
metadata = service / 'Metadata.appintents'
if metadata.exists():
    target = app / 'Metadata.appintents'
    if target.exists(): shutil.rmtree(target)
    shutil.copytree(metadata, target, symlinks=True)
    actions = target / 'extract.actionsdata'
    if actions.exists():
        content = actions.read_bytes().replace(b'9SideStore20RefreshAllAppsIntentV', b'16SideStoreSupport20RefreshAllAppsIntentV')
        content = content.replace(b'9SideStore26RefreshAllAppsWidgetIntentV', b'16SideStoreSupport26RefreshAllAppsWidgetIntentV')
        actions.write_bytes(content)

# SideBackup remains embedded in the service's Payload. Move its widget to the host.
plugins = service / 'PlugIns'
widget = args.widget if args.widget else plugins / 'AltWidgetExtension.appex'
if widget.exists():
    target = app / 'PlugIns' / 'LiveWidgetExtension.appex'
    shutil.copytree(widget, target, symlinks=True)
    wi = read_plist(target / 'Info.plist')
    wi['CFBundleIdentifier'] = 'app.ipastore.IPAStore.LiveWidget'
    wi['CFBundleVersion'] = info['CFBundleVersion']
    wi['CFBundleShortVersionString'] = info['CFBundleShortVersionString']
    # Preserve the executable name; the extension identifier, not its filename, establishes uniqueness.
    write_plist(target / 'Info.plist', wi)
    if plugins.exists(): shutil.rmtree(plugins)

# Xcode generated extension metadata can override static plists. Align every
# extension in the final package before signing, regardless of its origin.
for extension in (app / 'PlugIns').glob('*.appex'):
    value = read_plist(extension / 'Info.plist')
    value['CFBundleVersion'] = info['CFBundleVersion']
    value['CFBundleShortVersionString'] = info['CFBundleShortVersionString']
    write_plist(extension / 'Info.plist', value)

# Changed resource seals must not be passed off as upstream developer signatures.
for signature in sorted(app.rglob('_CodeSignature'), key=lambda p: len(p.parts), reverse=True):
    if signature.is_dir() and not signature.is_symlink(): shutil.rmtree(signature)
# Preserve requested capabilities as ad-hoc metadata for the real installer to re-sign.
# No real developer identity or provisioning is manufactured here. UNSIGNED00 is only
# a replaceable prefix in keychain group names; SideSign replaces it with the real team.
def expanded(value):
    if isinstance(value, str):
        return value.replace('$(AppIdentifierPrefix)', 'UNSIGNED00.').replace('$(APP_GROUP_SIDESTORE)', 'group.com.SideStore.SideStore').replace('$(APP_GROUP_ALTSTORE)', 'group.com.rileytestut.AltStore')
    if isinstance(value, list): return [expanded(v) for v in value]
    if isinstance(value, dict): return {k: expanded(v) for k, v in value.items()}
    return value

def sign_bundle(folder, template=None):
    command = ['codesign', '--force', '--sign', '-', '--timestamp=none']
    if template:
        entitlements = expanded(read_plist(template))
        entitlements.pop('application-identifier', None)
        entitlements.pop('com.apple.developer.team-identifier', None)
        request_file = stage / (folder.name + '.requested-entitlements.plist')
        request_file.write_bytes(plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=False))
        command += ['--entitlements', str(request_file), '--generate-entitlement-der']
    subprocess.run(command + [str(folder)], check=True)

for framework in sorted(app.rglob('*.framework'), key=lambda p: len(p.parts), reverse=True):
    if not framework.is_symlink(): sign_bundle(framework)
for extension in sorted((app / 'PlugIns').glob('*.appex')):
    if extension.name == 'LiveWidgetExtension.appex':
        template = root / '.github/sidelc/LiveWidgetExtension_adhoc.xml'
    else:
        template = root / extension.stem / (extension.stem + '.entitlements')
    sign_bundle(extension, template if template.exists() else None)
sign_bundle(app, root / 'entitlements.xml')

# Check every bundle has an executable, and extensions belong to the host namespace.
for folder in [app, *list((app / 'PlugIns').glob('*.appex'))]:
    bundle = read_plist(folder / 'Info.plist')
    assert (folder / bundle['CFBundleExecutable']).is_file(), f'Missing executable in {folder.name}'
    assert bundle['CFBundleIdentifier'].startswith(info['CFBundleIdentifier']), 'Foreign extension identifier'
args.output.parent.mkdir(parents=True, exist_ok=True)
if args.output.exists(): raise FileExistsError('Use a new output name instead of overwriting a build')
with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for current, directories, filenames in os.walk(stage / 'Payload', followlinks=False):
        for name in sorted(directories + filenames):
            path = Path(current) / name
            if path.name in {'.DS_Store', '__MACOSX'}: continue
            relative = path.relative_to(stage).as_posix()
            if path.is_symlink():
                entry = zipfile.ZipInfo(relative)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, os.readlink(path))
            elif path.is_file(): archive.write(path, relative)
with zipfile.ZipFile(args.output) as archive:
    assert archive.testzip() is None, 'Archive integrity check failed'
manifest = {
    'output_sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
    'bundle_identifier': info['CFBundleIdentifier'],
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'service_macho_type': 'MH_DYLIB',
    'status': 'Ad-hoc development package; requires real account provisioning and re-signing; device launch and renewal untested',
    'requested_entitlements': 'Engine templates preserved as ad-hoc metadata; no real team identity or profile embedded',
    'native_signing_bridge': 'IPAStoreSigningController',
    'signing_source_manifest_sha256': hashlib.sha256((root / 'ThirdParty/signing-source-manifest.json').read_bytes()).hexdigest(),
}
args.output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
