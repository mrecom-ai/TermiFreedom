#!/usr/bin/env python3
"""Package standard PNG icon representations into a native ICNS container."""
import struct
from pathlib import Path
root = Path(__file__).resolve().parent.parent
iconset = root / 'work/TermiFreedom.iconset'
representations = {
    'icp4': 'icon_16x16.png', 'icp5': 'icon_32x32.png', 'icp6': 'icon_32x32@2x.png',
    'ic07': 'icon_128x128.png', 'ic08': 'icon_256x256.png', 'ic09': 'icon_512x512.png',
    'ic10': 'icon_512x512@2x.png', 'ic11': 'icon_16x16@2x.png',
    'ic12': 'icon_32x32@2x.png', 'ic13': 'icon_128x128@2x.png', 'ic14': 'icon_256x256@2x.png',
}
chunks = []
for kind, name in representations.items():
    data = (iconset / name).read_bytes()
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(data) + 8) + data)
payload = b''.join(chunks)
(root / 'Assets/TermiFreedom.icns').write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
