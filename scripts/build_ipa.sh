#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'This build requires macOS with Xcode.' >&2
  exit 1
fi
command -v xcodegen >/dev/null
xcrun --sdk iphoneos --show-sdk-path >/dev/null
mkdir -p .build-ci reports artifacts

python3 - <<'PY'
import plistlib
from pathlib import Path
info = plistlib.loads(Path('Info.plist').read_bytes())
info.update({
    'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleExecutable': '$(EXECUTABLE_NAME)',
    'CFBundleName': '$(PRODUCT_NAME)',
    'CFBundlePackageType': 'APPL',
})
Path('.build-ci/Info-Xcode.plist').write_bytes(plistlib.dumps(info))
PY

xcodegen generate --spec project.yml
xcodebuild build \
  -project Folha.xcodeproj \
  -scheme Folha \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build-ci/device \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  | tee reports/device-build.log

mkdir -p artifacts/Payload
ditto .build-ci/device/Build/Products/Release-iphoneos/Folha.app artifacts/Payload/Folha.app
(
  cd artifacts
  ditto -c -k --keepParent Payload Folha-unsigned.ipa
  shasum -a 256 Folha-unsigned.ipa > Folha-unsigned.sha256
)
python3 - <<'PY'
import hashlib
import json
import plistlib
from pathlib import Path
ipa = Path('artifacts/Folha-unsigned.ipa')
info = plistlib.loads(Path('artifacts/Payload/Folha.app/Info.plist').read_bytes())
metadata = {
    'artifact': ipa.name,
    'bundle_identifier': info['CFBundleIdentifier'],
    'version': info.get('CFBundleShortVersionString'),
    'minimum_ios': info.get('MinimumOSVersion'),
    'platform': info.get('DTPlatformName'),
    'size_bytes': ipa.stat().st_size,
    'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
    'signed': False,
    'runtime_tests_executed': False,
    'installation_and_device_test': 'User will sign, install and test.',
}
Path('artifacts/Folha-unsigned.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
Path('artifacts/LEIA-ME.txt').write_text(
    'Folha - IPA sem assinatura\n'
    'Aplicativo proprio, sem marca ou arquivos do CamScanner.\n'
    'Requer assinatura pelo metodo de instalacao escolhido pelo usuario.\n'
    'Compilacao para iPhone; testes no aparelho ficam com o usuario.\n', encoding='utf-8')
PY
