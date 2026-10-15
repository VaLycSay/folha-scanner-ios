#!/bin/bash
set -euo pipefail
ROOT="$PRIVATE_WORK"
SRC="$GITHUB_WORKSPACE/private-rebrand"
mkdir -p "$ROOT/output"
clang -fobjc-arc -DREA_FLOW_TESTING -framework Foundation "$SRC/flow.m" "$SRC/flow_host_tests.m" -o "$ROOT/flow-tests"
"$ROOT/flow-tests" > "$ROOT/output/flow-tests.log" 2>&1
clang -fobjc-arc -DREA_FLOW_TESTING -framework Foundation "$SRC/ux_policy.m" "$SRC/policy_tests.m" -o "$ROOT/policy-tests"
"$ROOT/policy-tests" > "$ROOT/output/policy-tests.log" 2>&1
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
clang -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -dynamiclib \
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
  -install_name '@rpath/ScannerREAFlow.dylib' \
  "$SRC/flow.m" "$SRC/continuous.m" "$SRC/ux_policy.m" "$SRC/ux_ios.m" -o "$ROOT/output/ScannerREAFlow.dylib"
codesign --force --sign - "$ROOT/output/ScannerREAFlow.dylib"
codesign --verify --strict "$ROOT/output/ScannerREAFlow.dylib"
SIMSDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
APP="$ROOT/ScannerREATests.app"
mkdir -p "$APP"
clang -target "$ARCH-apple-ios15.0-simulator" -isysroot "$SIMSDK" \
  -fobjc-arc -DREA_FLOW_TESTING -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
  "$SRC/continuous.m" "$SRC/ux_ios.m" "$SRC/ux_tests.m" -o "$APP/ScannerREATests"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.valyc.scanner-ux-tests</string>
<key>CFBundleName</key><string>Scanner REA Tests</string>
<key>CFBundleExecutable</key><string>ScannerREATests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>4.0</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict>
<key>UIWindowSceneSessionRoleApplication</key><array><dict>
<key>UISceneConfigurationName</key><string>Tests</string>
<key>UISceneDelegateClassName</key><string>TestSceneDelegate</string>
</dict></array></dict></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
UDID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=[v for a in json.load(sys.stdin)["devices"].values() for v in a if v.get("isAvailable") and "iPhone" in v["name"]]; d.sort(key=lambda v:v["state"]!="Booted"); assert d, "No iPhone simulator"; print(d[0]["udid"])')"
STATE="$(xcrun simctl list devices -j | python3 -c 'import json,sys; print(next(v["state"] for a in json.load(sys.stdin)["devices"].values() for v in a if v["udid"]==sys.argv[1]))' "$UDID")"
if [ "$STATE" != Booted ]; then xcrun simctl boot "$UDID"; fi
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
export UDID
python3 - <<'PY'
import os, subprocess
from pathlib import Path
root=Path(os.environ["PRIVATE_WORK"])
with (root/"output"/"simulator.log").open("w") as log:
    p=subprocess.run(["xcrun","simctl","launch","--console","--terminate-running-process",
      os.environ["UDID"],"com.valyc.scanner-ux-tests"],stdout=log,stderr=subprocess.STDOUT,timeout=180)
    if p.returncode: raise SystemExit(p.returncode)
PY
CONTAINER="$(xcrun simctl get_app_container "$UDID" com.valyc.scanner-ux-tests data)"
cp "$CONTAINER/Documents/ux-tests.json" "$ROOT/output/ux-tests.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d); assert d["status"]=="passed" and d["assertions"]>=50' "$ROOT/output/ux-tests.json"
lipo -info "$ROOT/output/ScannerREAFlow.dylib" > "$ROOT/output/dylib-architecture.txt"
otool -L "$ROOT/output/ScannerREAFlow.dylib" > "$ROOT/output/dylib-dependencies.txt"
cd "$ROOT/output"
zip -q "$ROOT/adapter.zip" ScannerREAFlow.dylib *.json *.log *.txt
