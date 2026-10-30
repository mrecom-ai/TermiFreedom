#!/usr/bin/env python3
"""Install the local build in Applications, leaving one searchable app copy."""
import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'app.termifreedom.mac'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)

def identity(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        return plistlib.load(stream)['CFBundleIdentifier']

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=Path('/Applications'), help='Applications folder; ~/Applications also works')
    args = parser.parse_args()
    source = ROOT / 'outputs/TermiFreedom.app'
    destination = args.destination.expanduser().absolute()
    target = destination / source.name
    if identity(source) != APP_ID:
        raise SystemExit('The source app identity is incorrect.')
    run('codesign', '--verify', '--strict', source)
    processes = run('ps', '-axo', 'comm=', capture_output=True, text=True).stdout.splitlines()
    if any(Path(line.strip()).name == 'TermiFreedom' for line in processes):
        raise SystemExit('Quit TermiFreedom before installing. No processes were stopped.')
    if target.exists() and (target.is_symlink() or identity(target) != APP_ID):
        raise SystemExit('A different app or symbolic link occupies the destination. It was preserved.')
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.TermiFreedom-install-', suffix='.noindex', dir=destination) as temp:
        temp = Path(temp)
        staged = temp / source.name
        run('ditto', source, staged)
        run('codesign', '--verify', '--strict', staged)
        previous = temp / 'previous.app'
        if target.exists():
            backup = ROOT / 'work.noindex'; backup.mkdir(exist_ok=True)
            fd, name = tempfile.mkstemp(prefix='previous-install-', suffix='.zip', dir=backup)
            os.close(fd); Path(name).unlink()
            run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', target, name)
            target.rename(previous)
        try:
            staged.rename(target)
        except BaseException:
            if previous.exists(): previous.rename(target)
            raise
        # A successful install supersedes the output bundle. Archives remain in outputs.
        subprocess.run([LSREGISTER, '-u', str(source)], check=False)
        shutil.rmtree(source)
        run(LSREGISTER, '-f', target)
    print(f'Installed {target}. The app was not launched; saved data was not changed.')

if __name__ == '__main__':
    main()
