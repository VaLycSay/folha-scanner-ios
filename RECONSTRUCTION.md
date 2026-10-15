# Scanner REA 0.4.0

Independent implementation guided by static reverse-engineering evidence from
the historical CamScanner 5.26.12 reference and current 7.27.0 UI resources. Not the original application,
not a renamed original binary, and not a claim of full functional/visual parity.

## Implemented scope

- Search-first home, tool grid, recent documents and centered camera navigation.
- Files list/grid, sorting, document selection and batch PDF sharing.
- PDF/image file import, PDF/JPG/TXT export and a document export panel.
- Page thumbnail grid, image/text switch and a refined editor presentation.
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
The original application was not executed by the build runner for runtime or
pixel comparison. A user-supplied recording of the current app additionally
guides the Home, Files, Tools and camera layout; it does not show the full editor.
The official 7.27.0 IPA has an encrypted main executable. Its REA resource
evidence is not a recovery of its current native implementation. Official
marketing images informed layout, but some contain visibly older sample dates
and do not establish the exact current runtime interface. Full equivalence
remains unproven; the 128-case kernel fixture is limited to historical contracts.

## White-label fidelity pass

Version 0.5.0 adds actual live video-frame rectangle detection, corner overlay,
stability feedback, optional automatic capture with batch duplicate protection,
and tap-to-focus. LIVE-CAPTURE.md documents the frame geometry, controls and
physical-device acceptance boundary. This is an independently implemented
Vision detector, not the original vendor's recovered image-processing engine.

WHITE-LABEL-SPEC.md separates observed appearance, actual workflows and verified
results. This pass adds compact quick tools, contextual Recent actions, Files
selection in list/grid, grouped tools and adaptive editor presentation. Reopened
crop cancellation restores the previous recipe and recognized text. Branding
remains Scanner REA, with our own code and artwork; this is not an official
CamScanner white-label distribution or a modified original executable.

The current IPA was also projected through REA's Apple application inventory.
Private asset-catalog metadata and Interface Builder properties guide further
comparison. These static facts do not establish runtime pixel equivalence or
recover the encrypted implementation. Missing proprietary features remain
explicitly listed below, regardless of a successful build or test count.

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
