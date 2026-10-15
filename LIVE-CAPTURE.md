# Live document capture, 0.5.0

The camera analyzes actual AVCapture video frames with Vision rectangle
detection. The outline follows the four detected corners; it is not a fixed
guide or prerecorded demonstration. Processing is local and independent of
CamScanner's proprietary algorithms.

- Live detection starts enabled. Tap the viewfinder control to turn it off/on.
- A teal outline follows the page. A stronger outline indicates stability.
- Manual shutter remains available without a detected rectangle.
- Auto starts disabled. Enable it to capture only after a stable observation
  window with all four corners visible. Its ring represents stability progress.
- Batch Auto waits for the page to leave before rearming, avoiding repeated
  photos of the same page. Manual capture can still be used deliberately.
- QR mode, backgrounding, interruptions, modals and photo capture suspend live
  results. Generation checks discard stale in-flight results.
- Video frames are dropped when late and analyzed at most about seven times
  per second. Full-resolution original photos remain preserved. Existing still
  image processing redetects crop corners rather than applying preview pixels
  to a differently sized photograph.
- Tap the preview to focus/expose the document. Availability depends on hardware.

## Geometry contract

Rear camera, portrait-only UI; video-data buffers explicitly unrotated and
unmirrored. Vision receives orientation right. Its lower-left-origin portrait
points map to unrotated capture-device coordinates as (1-y, 1-x), then pass
through AVCaptureVideoPreviewLayer's conversion for rotation/aspect-fill.
No fixed phone dimensions, copied screen coordinates or forced front-camera
transform are used.

## Evidence and verification boundary

The supplied original runtime recording shows a teal document outline. Current
CamScanner resources name automatic capture and automatic crop. They do not
disclose its detection algorithm, thresholds, timing or blur/quality policy.
These implementation parameters are our own, with geometric, lifecycle and
synthetic Vision tests. They are not a recovered native CamScanner engine.

Simulator tests exercise synthetic images, not a physical live camera. Physical
acceptance must include tilted and moving paper, low contrast, partial framing,
different distances, portrait overlay alignment, single/batch mode, removing a
page to rearm Auto, manual override, QR switching and background/foreground.
Visual and full-product equivalence remain separate from a passing test suite.
