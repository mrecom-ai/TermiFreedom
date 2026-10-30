#!/usr/bin/env python3
"""Audit the explicit public-source boundary without printing private server values."""
import argparse
import fnmatch
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBLIC_DIRECTORIES = ('Sources', 'Tests', 'Vendor', 'Assets', 'scripts', 'docs', '.github')
PUBLIC_FILES = ('Package.swift', '.gitignore', 'README.md', 'LICENSE')
PRIVATE_NAMES = ('servers.json', 'known_hosts', '*.pem', '*.key', '*.p12', '*.pfx', 'id_rsa*', 'id_ed25519*', '.env', '.env.*')

def public_files():
    for directory in PUBLIC_DIRECTORIES:
        base = ROOT / directory
        if base.exists():
            for path in sorted(base.rglob('*')):
                if path.is_file() and not any(part in path.parts for part in ('.DS_Store', '__pycache__', 'com.apple.DeveloperTools', '.build', '.swiftpm')):
                    yield path
    for filename in PUBLIC_FILES:
        path = ROOT / filename
        if path.is_file():
            yield path

def private_tokens(runtime_file):
    if not runtime_file.exists():
        return set(), 0
    document = json.loads(runtime_file.read_text())
    tokens = set()
    for server in document['servers']:
        for key in ('host', 'name', 'identityFile'):
            value = server.get(key, '')
            if value:
                tokens.add(value.encode('utf-8'))
    return tokens, len(document['servers'])

def audit(entries, tokens):
    errors = []
    count = 0
    for name, data in entries:
        count += 1
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            errors.append(f'Unsafe archive path: {name}')
        # The archive has one top-level project folder; filesystem paths do not.
        parts = relative.parts[1:] if relative.parts and relative.parts[0] == 'TermiFreedom' else relative.parts
        if not parts or (parts[0] not in PUBLIC_DIRECTORIES and '/'.join(parts) not in PUBLIC_FILES):
            errors.append(f'Unexpected public-source entry: {name}')
        if any(fnmatch.fnmatch(relative.name, pattern) for pattern in PRIVATE_NAMES):
            errors.append(f'Private-data filename inside public source: {name}')
        if any(token in data for token in tokens):
            errors.append(f'Private runtime server value found in: {name}')
        if re.search(rb'^-----BEGIN (?:OPENSSH|RSA|EC|DSA|ENCRYPTED) PRIVATE KEY-----\r?\n[A-Za-z0-9+/=]{32,}\r?\n', data, re.M):
            errors.append(f'Private key material found in: {name}')
    return count, errors

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--runtime-data', type=Path, default=Path.home() / 'Library/Application Support/TermiFreedom/servers.json')
    args = parser.parse_args()
    runtime = args.runtime_data
    if not runtime.exists():
        # This spelling is read from the compatibility map, never used as the current app identity.
        compatibility = (ROOT / 'Sources/TermiFreedomCore/LegacyCompatibility.swift').read_text()
        match = re.search(r'dataDirectoryName = "([^"]+)"', compatibility)
        if match:
            runtime = Path.home() / 'Library/Application Support' / match.group(1) / 'servers.json'
    tokens, server_count = private_tokens(runtime)
    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            entries = [(item.filename, archive.read(item)) for item in archive.infolist() if not item.is_dir()]
    else:
        entries = [(str(path.relative_to(ROOT)), path.read_bytes()) for path in public_files()]
    count, errors = audit(entries, tokens)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print(f'PASS: {count} public files checked; no values from {server_count} private runtime servers; no private-key material or runtime-data files.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
