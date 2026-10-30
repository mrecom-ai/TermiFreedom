#!/usr/bin/env python3
"""Create a source-only archive from the audited public allowlist."""
import importlib.util
import subprocess
import sys
import zipfile
from pathlib import Path
root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'scripts/audit-source.py')], check=True)
spec = importlib.util.spec_from_file_location('source_audit', root / 'scripts/audit-source.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
output = root / 'outputs/TermiFreedom-source.zip'
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in audit.public_files():
        archive.write(path, Path('TermiFreedom') / path.relative_to(root))
subprocess.run([sys.executable, str(root / 'scripts/audit-source.py'), '--archive', str(output)], check=True)
print('Created outputs/TermiFreedom-source.zip')
