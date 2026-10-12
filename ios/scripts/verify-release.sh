#!/bin/sh
# Run on macOS against the actual signed Release .app, before distribution.
set -eu
app_path=${1:?Usage: verify-release.sh /path/to/MedPrep.app}
release_audit_dir=$(mktemp -d)
trap 'rm -rf "$release_audit_dir"' EXIT HUP INT TERM
codesign --verify --deep --strict "$app_path"
codesign -d --entitlements - "$app_path" > "$release_audit_dir/entitlements.plist"
python3 - "$app_path" "$release_audit_dir/entitlements.plist" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Info.plist').read_bytes())
entitlements = plistlib.loads(pathlib.Path(sys.argv[2]).read_bytes())
assert entitlements.get('get-task-allow') is not True, 'Debugger entitlement must be absent or false'
assert entitlements.get('com.apple.developer.devicecheck.appattest-environment') == 'production', 'Production App Attest required'
assert info.get('AppAttestEnvironment') == 'production', 'App configuration must match production entitlement'
assert not list(app.rglob('*.dSYM')), 'dSYM bundles must be outside the distributed app'
assert not list(app.rglob('*.swift')), 'Swift source must not ship'
assert not list(app.rglob('*.p8')), 'Apple private keys must not ship'
ats = info['NSAppTransportSecurity']
assert ats.get('NSAllowsArbitraryLoads') is not True
assert ats.get('NSAllowsArbitraryLoadsInWebContent') is not True
import base64
for host, item in ats.get('NSPinnedDomains', {}).items():
    pins = {x['SPKI-SHA256-BASE64'] for x in item.get('NSPinnedLeafIdentities', [])}
    assert len(pins) >= 2, f'Current and backup leaf pins required: {host}'
    assert all(len(base64.b64decode(x, validate=True)) == 32 for x in pins), f'Invalid pin: {host}'
assert 'new.medpreparation.com' in ats.get('NSPinnedDomains', {}), 'Main site pin configuration required'
print('Signed app configuration checks passed. Physical-device capture tests and App Store availability checks remain required.')
PY
