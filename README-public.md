# Folha

Independent, on-device document scanner for iPhone. Written in Swift with
SwiftUI, VisionKit, Vision, Core Image and PDFKit. Requires iOS 17 or later.

Features: multi-page capture, photo import, perspective correction, image
filters, rotation, local document library, OCR and searchable PDF export.

No account, subscription, advertising service or remote document upload is
implemented. Scanned documents are stored locally on the device.

## Build

On macOS with Xcode and XcodeGen installed:

```sh
bash scripts/build_ipa.sh
```

The GitHub Actions workflow builds `artifacts/Folha-unsigned.ipa`. It does not
sign or install the app and does not use Apple account credentials. Signing
and device installation are separate steps handled by the user.

The included tests are available for development but are not executed by the
IPA-only workflow. Camera behavior and scan quality require device testing.

This repository contains only the independent implementation and its build
files, not third-party app binaries, extracted resources or private data.
