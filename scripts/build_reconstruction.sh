#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'Requires macOS with Xcode.' >&2; exit 2; }
mkdir -p reports artifacts .build-ci
python3 - <<'PY'
import plistlib
from pathlib import Path
info = plistlib.loads(Path('Info.plist').read_bytes())
info.update({'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)',
             'CFBundleExecutable':'$(EXECUTABLE_NAME)',
             'CFBundleName':'$(PRODUCT_NAME)', 'CFBundlePackageType':'APPL'})
Path('.build-ci/Info-Xcode.plist').write_bytes(plistlib.dumps(info))
PY
xcodegen generate --spec project.yml
swiftc -parse-as-library Sources/Folha/ReconstructedAdjustmentContract.swift \
  Sources/Folha/RecoveredPixelAdjustment.swift scripts/compare_recovered_pixels.swift \
  -o .build-ci/pixel-regression
.build-ci/pixel-regression Tests/Fixtures/recovered-pixels.json | tee reports/recovered-pixels.log
xcrun simctl list devices available -j > reports/simulators.json
SIMULATOR_ID="$(python3 - <<'PY'
import json
from pathlib import Path
devices = json.loads(Path('reports/simulators.json').read_text())['devices']
choices = [(runtime, d) for runtime, rows in devices.items() if '.iOS-' in runtime
           for d in rows if d.get('isAvailable') and d['name'].startswith('iPhone')]
if not choices: raise SystemExit('No iPhone simulator. Tests cannot be skipped.')
choices.sort(key=lambda x:(x[0], 'Pro' in x[1]['name'], x[1]['name']), reverse=True)
print(choices[0][1]['udid'])
PY
)"
printf 'Simulator: %s\n' "$SIMULATOR_ID"
xcrun simctl boot "$SIMULATOR_ID" || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
set +e
xcodebuild test -project Folha.xcodeproj -scheme Folha -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO \
  -derivedDataPath .build-ci/simulator -resultBundlePath reports/ScannerTests.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  > reports/simulator-tests.log 2>&1
TEST_STATUS=$?
set -e
tail -n 100 reports/simulator-tests.log
if [[ -d reports/ScannerTests.xcresult ]]; then
  xcrun xcresulttool get test-results summary --path reports/ScannerTests.xcresult \
    --format json > reports/test-summary.json || true
  xcrun xcresulttool export attachments --path reports/ScannerTests.xcresult \
    --output-path reports/screenshots || true
fi
[[ "$TEST_STATUS" -eq 0 ]] || exit "$TEST_STATUS"
xcodebuild build -project Folha.xcodeproj -scheme Folha -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .build-ci/device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  > reports/device-build.log 2>&1 || { tail -n 100 reports/device-build.log; exit 1; }
tail -n 12 reports/device-build.log
mkdir -p artifacts/Payload
ditto .build-ci/device/Build/Products/Release-iphoneos/Folha.app artifacts/Payload/Folha.app
(cd artifacts && ditto -c -k --keepParent Payload Scanner-REA-0.3.0-unsigned.ipa)
python3 scripts/check_ipa.py artifacts/Scanner-REA-0.3.0-unsigned.ipa
shasum -a 256 artifacts/Scanner-REA-0.3.0-unsigned.ipa > artifacts/Scanner-REA-0.3.0-unsigned.sha256
cp RECONSTRUCTION.md artifacts/LEIA-ME.md
printf '%s\n' 'IPA compiled; simulator tests passed. Physical camera and signing remain device tests.'
