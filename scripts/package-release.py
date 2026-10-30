#!/usr/bin/env python3
"""Build ZIP/DMG downloads. Public releases require Developer ID and notarization."""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)

def notarize(path, profile, report):
    result = run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile,
                 '--wait', '--timeout', '15m', '--output-format', 'json', capture_output=True, text=True)
    report.write_text(result.stdout)
    if json.loads(result.stdout).get('status') != 'Accepted':
        raise SystemExit(f'Notarization was not accepted. See {report}. No public package was produced.')
    run('xcrun', 'stapler', 'staple', path)
    run('xcrun', 'stapler', 'validate', path)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--development', action='store_true', help='Explicitly create unnotarized development downloads')
    parser.add_argument('--skip-build', action='store_true', help='Package the existing output app after signature checks')
    args = parser.parse_args()
    identity = os.environ.get('TERMIFREEDOM_SIGNING_IDENTITY', '')
    profile = os.environ.get('TERMIFREEDOM_NOTARY_PROFILE', '')
    if not args.development and (not identity.startswith('Developer ID Application:') or not profile):
        parser.error('Public packaging requires TERMIFREEDOM_SIGNING_IDENTITY (Developer ID Application) and TERMIFREEDOM_NOTARY_PROFILE. Use --development only for local testing.')
    if not args.skip_build:
        run(ROOT / 'scripts/build-app.sh', cwd=ROOT)
    app = ROOT / 'outputs/TermiFreedom.app'
    run('codesign', '--verify', '--strict', app)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info['CFBundleIdentifier'] != 'app.termifreedom.mac' or info.get('TermiFreedomPreviewMode'):
        raise SystemExit('Refusing to package a preview or differently identified app.')
    architecture = run('lipo', '-archs', app / 'Contents/MacOS/TermiFreedom', capture_output=True, text=True).stdout.strip().replace(' ', '-')
    version = info['CFBundleShortVersionString']
    stem = f'TermiFreedom-{version}-{architecture}' + ('-development' if args.development else '')
    output = ROOT / 'outputs'
    scratch = ROOT / 'work.noindex'; scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='release-', dir=scratch) as temp:
        temp = Path(temp)
        volume = temp / 'volume'; volume.mkdir()
        staged = volume / 'TermiFreedom.app'
        # ditto preserves executable bits, symlinks, resource forks, and signing metadata.
        run('ditto', app, staged)
        if not args.development:
            run('codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity, staged)
            submission = temp / 'notary-upload.zip'
            run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', staged, submission)
            # A ZIP is submitted; the ticket is stapled to the app inside it.
            result = run('xcrun', 'notarytool', 'submit', submission, '--keychain-profile', profile,
                         '--wait', '--timeout', '15m', '--output-format', 'json', capture_output=True, text=True)
            report = scratch / f'{stem}-app-notary.json'; report.write_text(result.stdout)
            if json.loads(result.stdout).get('status') != 'Accepted':
                raise SystemExit(f'App notarization was not accepted. See {report}.')
            run('xcrun', 'stapler', 'staple', staged)
            run('xcrun', 'stapler', 'validate', staged)
            run('spctl', '--assess', '--type', 'execute', '--verbose=2', staged)
        (volume / 'Applications').symlink_to('/Applications', target_is_directory=True)
        instructions = (ROOT / 'docs/INSTALL.txt').read_text()
        if args.development:
            instructions = 'DEVELOPMENT BUILD — locally signed, not notarized for public distribution.\n\n' + instructions
        (volume / 'Install TermiFreedom.txt').write_text(instructions)
        shutil.copy2(ROOT / 'Assets/TermiFreedom.icns', volume / '.VolumeIcon.icns')
        # The custom icon is optional; layout needs no Finder automation or extra tooling.
        setfile = subprocess.run(['xcrun', '--find', 'SetFile'], capture_output=True, text=True)
        if setfile.returncode == 0:
            run(setfile.stdout.strip(), '-a', 'C', volume)
        archive = temp / f'{stem}.zip'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', staged, archive)
        image = temp / f'{stem}.dmg'
        run('hdiutil', 'create', '-volname', 'TermiFreedom', '-srcfolder', volume,
            '-format', 'UDZO', '-fs', 'HFS+', image)
        if not args.development:
            run('codesign', '--sign', identity, '--timestamp', image)
            notarize(image, profile, scratch / f'{stem}-dmg-notary.json')
        # Publish outputs only after every required signing/notarization step succeeds.
        for path in [archive, image]:
            os.replace(path, output / path.name)
        sums = ''.join(f'{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}\n'
                       for name in [archive.name, image.name])
        (output / f'{stem}-SHA256SUMS.txt').write_text(sums)
    print(f'Created {stem}.zip, .dmg, and -SHA256SUMS.txt in outputs/')
    if args.development:
        print('Development downloads are not notarized. Do not label them as a signed public release.')

if __name__ == '__main__':
    main()
