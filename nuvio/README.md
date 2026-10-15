# Nuvio iOS Lab r1

Experimental, unofficial source-based build. Base: Nuvio Mobile 0.5.10-beta,
commit 6d435785c0e082ae3d4fbb8152e1ff5e45c2e575. Original GPL-3.0 notices,
dependencies, MPVKit, Nuvio Engine, app feature policies and settings are retained.

## Changes

- Serialize audio-session changes away from the UI thread while preserving the
  official mix-with-other-audio setting. Adapted from Enhanced acb4383.
- Clear an abandoned PiP startup state on returning to the app. Compatible
  portion of Enhanced 4b435d6; no speculative hardware-decoder replacement.
- Do not resume a video that was explicitly paused before backgrounding.
- Keep both player control layouts visible while the timeline is held, including
  a stationary finger; release the state on disposal. Adapted from ac1b6ed.

## Build and evidence

The branch only contains the harness and patches; upstream is fetched at its
fixed commit. `apply-upgrades.mjs` matches all source anchors before writing and
records original/modified hashes. CI retains test reports and the unsigned IPA
as temporary artifacts, not a public release.

The original simulator suite, focused Compose UI regressions and iOS UI smoke
tests have separate results. UI smoke tests cover startup, foreground return and
rotation without real accounts; they do NOT prove media playback, PiP, downloads,
AirPlay, HDR, providers or performance on a physical iPhone.

## Runtime configuration

The build reads the public Nuvio discovery document. No user's account/password
or original-app private credentials are extracted. TMDB enrichment still needs
an operator-owned key, supplied through NUVIO_TMDB_API_KEY on the runner or the
existing app settings. Missing configuration is a limitation, not a removed UI
feature or a claim of full functional parity. Third-party account login and
services must be confirmed on-device.

## Installation

Unsigned IPA: re-sign with the user's chosen installation method. The official
bundle ID is preserved; installation may replace an existing Nuvio copy. Export
settings first or choose a separate bundle ID in the signing tool. No device
installation is performed by this harness.

## Sources

- https://github.com/NuvioMedia/NuvioMobile/tree/0.5.10-beta
- https://github.com/luqmanfadlli/NuvioMobile-Enhanced/commit/acb4383fa9c9d568b116b08fa89275dfc8d07856
- https://github.com/luqmanfadlli/NuvioMobile-Enhanced/commit/4b435d6525bd3017b39655f51344765d075abc5f
- https://github.com/luqmanfadlli/NuvioMobile-Enhanced/commit/ac1b6ed69376b37ee1612b87f4ee9f5b4ee79026
- https://github.com/Jakeschincariol/replica-skill

Replica is used for reconnaissance, evidence, feature preservation and comparison.
Its clean-room rebuilding branch is intentionally not used: the user requested
reuse of GPL-licensed source rather than a replacement implementation.
