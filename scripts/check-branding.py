#!/usr/bin/env python3
"""Reject stale branding in active source and the release bundle."""
import plistlib,re,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent.parent
compatibility=root/'Sources/TermiFreedomCore/LegacyCompatibility.swift'
previous=re.search(r'dataDirectoryName = "([^"]+)"',compatibility.read_text()).group(1).removesuffix('SSH').casefold()
for directory in ['Sources','Tests','scripts','docs']:
 for path in (root/directory).rglob('*'):
  if path==compatibility or not path.is_file() or '__pycache__' in path.parts:continue
  try:text=path.read_text()
  except UnicodeDecodeError:continue
  if previous in text.casefold():raise SystemExit('Previous branding outside the compatibility map: '+str(path.relative_to(root)))
app=root/'outputs/TermiFreedom.app'
with (app/'Contents/Info.plist').open('rb') as file:info=plistlib.load(file)
for key in ['CFBundleName','CFBundleDisplayName','CFBundleExecutable']:
 assert info[key]=='TermiFreedom',key
assert info['CFBundleIdentifier']=='app.termifreedom.mac'
for key,value in info.items():
 if key.endswith('UsageDescription'):assert 'TermiFreedom' in value and previous not in value.casefold(),key
signature=subprocess.run(['codesign','-d','--verbose=2',str(app)],capture_output=True,text=True,check=True).stderr
assert 'Identifier=app.termifreedom.mac' in signature
print('PASS: active source, app identity, executable, signature and permission-purpose strings use TermiFreedom. Previous identifiers exist only in the compatibility map.')
