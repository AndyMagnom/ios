#!/usr/bin/env python3
"""Install operator-supplied current/backup SPKI pins into the app's Info.plist."""
import argparse
import base64
import json
import pathlib
import plistlib
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('mapping', type=pathlib.Path, help='JSON object: hostname -> list of base64 SHA-256 SPKI pins')
args = parser.parse_args()
required = {'new.medpreparation.com', 'med.medpreparation.com', 'test.medpreparation.com', 'moodle.cooky.theworkpc.com'}
mapping = json.loads(args.mapping.read_text())
if not isinstance(mapping, dict) or not required.issubset(mapping):
    parser.error('Mapping must contain all four Moodle hostnames')
entries = {}
for host, pins in mapping.items():
    if not isinstance(host, str) or host != host.lower() or len(host) > 253 or not all(
            re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in host.split('.')):
        parser.error('Invalid exact hostname')
    if not isinstance(pins, list) or any(not isinstance(pin, str) for pin in pins) or len(set(pins)) < 2:
        parser.error(f'At least two distinct current/backup pins required for {host}')
    for pin in pins:
        try:
            decoded = base64.b64decode(pin, validate=True)
            if len(decoded) != 32 or base64.b64encode(decoded).decode() != pin:
                raise ValueError('Noncanonical SHA-256 pin')
        except (ValueError, TypeError):
            parser.error(f'Invalid SHA-256 SPKI pin for {host}')
    entries[host] = {'NSIncludesSubdomains': False,
                     'NSPinnedLeafIdentities': [{'SPKI-SHA256-BASE64': pin} for pin in dict.fromkeys(pins)]}
path = pathlib.Path(__file__).resolve().parents[1] / 'MedPrep' / 'Info.plist'
info = plistlib.loads(path.read_bytes())
info['NSAppTransportSecurity']['NSPinnedDomains'] = entries
path.write_bytes(plistlib.dumps(info, sort_keys=False))
print('Installed public-key pins. Verify live and backup certificates before signing.')
