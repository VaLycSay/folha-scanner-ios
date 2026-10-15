"""Validate the structure of our generated IPA, never a proprietary reference."""
import hashlib
import json
import plistlib
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
with zipfile.ZipFile(path) as package:
    names = package.namelist()
    info = plistlib.loads(package.read('Payload/Folha.app/Info.plist'))
    assert info['CFBundleIdentifier'] == 'com.valyc.folha.scanner', 'Unexpected bundle identity'
    executable = 'Payload/Folha.app/' + info['CFBundleExecutable']
    assert executable in names, 'App executable missing'
    assert not any('CamScanner' in name or 'ICELib' in name or name.endswith('.source') for name in names), 'Reference artifact in deliverable'
    magic = package.read(executable)[:4].hex()
    assert magic in {'cffaedfe', 'cefaedfe', 'cafebabe', 'bebafeca'}, 'Executable is not Mach-O'
result = {
    'bundle_id': info['CFBundleIdentifier'],
    'version': info['CFBundleShortVersionString'],
    'minimum_os': info.get('MinimumOSVersion'),
    'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
    'bytes': path.stat().st_size,
    'signature': 'not provided; external signing required',
    'scope': 'package structure, not proof of physical-device execution'
}
path.with_suffix('.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps(result))
