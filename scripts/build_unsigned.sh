#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'Este caminho de compilacao precisa de macOS com Xcode.' >&2
  exit 2
fi
command -v xcodegen >/dev/null
xcrun --sdk iphoneos --show-sdk-path >/dev/null
mkdir -p reports artifacts .build-ci
python3 - <<'PY'
import plistlib
from pathlib import Path
info = plistlib.loads(Path('Info.plist').read_bytes())
info.update({
    'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleExecutable': '$(EXECUTABLE_NAME)',
    'CFBundleName': '$(PRODUCT_NAME)',
    'CFBundlePackageType': 'APPL'
})
Path('.build-ci/Info-Xcode.plist').write_bytes(plistlib.dumps(info))
PY
xcodegen generate --spec project.yml
xcrun simctl list devices available --json > reports/simulators.json
SIMULATOR_ID="$(python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path('reports/simulators.json').read_text())
choices = [(runtime, device) for runtime, devices in data['devices'].items()
           if '.iOS-' in runtime for device in devices
           if device.get('isAvailable') and device['name'].startswith('iPhone')]
if not choices:
    raise SystemExit('Nenhum simulador iPhone disponivel; nao omitir os testes.')
choices.sort(key=lambda value: ('18 Pro' in value[1]['name'], value[0], value[1]['name']), reverse=True)
print(choices[0][1]['udid'])
PY
)"
printf 'SIMULATOR_ID=%s\n' "$SIMULATOR_ID"
xcodebuild test -project Folha.xcodeproj -scheme Folha -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath .build-ci/simulator -resultBundlePath reports/FolhaTests.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  | tee reports/simulator-tests.log
xcodebuild build -project Folha.xcodeproj -scheme Folha -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build-ci/device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  | tee reports/device-build.log
mkdir -p artifacts/Payload
ditto .build-ci/device/Build/Products/Release-iphoneos/Folha.app artifacts/Payload/Folha.app
(
  cd artifacts
  ditto -c -k --keepParent Payload Folha-unsigned.ipa
)
python3 scripts/check_ipa.py artifacts/Folha-unsigned.ipa
shasum -a 256 artifacts/Folha-unsigned.ipa > artifacts/Folha-unsigned.sha256
printf '%s\n' 'IPA SEM ASSINATURA: precisa ser assinado antes de instalar no iPhone.' > artifacts/LEIA-ME.txt
