# Scanner REA 0.3.0

Independent implementation guided by static reverse-engineering evidence from
the historical CamScanner 5.26.12 iOS reference. Not the original application,
not a renamed original binary, and not a claim of full functional/visual parity.

## Implemented scope

- Document library, search, photo import, single/batch camera, QR text reading.
- Local source preservation, append/replace pages, page reordering and removal.
- Perspective crop and rotation.
- Recovered filter IDs/order; independently implemented Core Image filter effects.
- Recovered brightness/contrast/detail contract and byte-matched adjustment kernel.
- Native toolbar structure, adjustment snapshot cancel/commit.
- Text, ink/signature and opaque rectangle overlays.
- OCR after overlays; searchable or raster PDF, preview and system share sheet.
- Redacted exports discard OCR intersecting masks. Original files are retained
  locally for reediting; sharing the app's complete storage is NOT a safe export.

## Provenance boundary

Published source, icons (SF Symbols), drawings and numeric test fixtures are our
independent implementation. Original IPA, native binary, extracted assets,
decompilation and private analysis are NOT in this repository.

Six primary filters and the processed toolbar order follow recovered contracts.
Some fonts, colors, capture controls and image effects are independent choices.
The original application was not executed for runtime or pixel comparison.

## Build and verification

macOS + Xcode + XcodeGen: run bash scripts/build_reconstruction.sh.
It executes the 128-case recovered pixel fixture, XCTest and UI tests with
synthetic documents, then builds an unsigned arm64 iPhone IPA. CI logs and
screenshots are evidence of those runs, not of physical camera operation.

The --uitesting namespace is separate from user documents. No real documents
are used in automated tests. Camera hardware, installation/signing, visual
parity and performance on a physical iPhone remain device-validation steps.

## Not included

Cloud account/sync; paid-provider services; spreadsheet reconstruction; native
ID-card/passport specialization; certificate-based digital signing; the entire
CamScanner feature set. These are not represented by inert toolbar buttons.

The IPA needs external signing before iPhone installation. No Apple password
or original-app resources are included.
