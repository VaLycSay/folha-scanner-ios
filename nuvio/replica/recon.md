# Nuvio iOS: reconnaissance and preservation contract

Date: 2026-10-15. Target: official Nuvio Mobile 0.5.10-beta, not a generic player.
The official release includes native PiP and subtitle AutoSync already. These
are baseline features, not new work claimed by this fork.

Public-source inventory (not an on-device walkthrough): home/catalog, search,
title/episodes, stream selection, player, subtitle/audio panels, library,
downloads, profiles, settings/integrations. Routes and visual parity remain to
be measured on the iPhone; no numerical parity score is claimed.

Protected flow: discover -> choose title/episode -> choose an authorized source
-> play -> select audio/subtitles -> resume later. Also retain downloads,
widgets, account/profile settings and upstream PiP.

Selected Enhanced work: compatible PiP state handling, asynchronous audio-session
operations and timeline interaction state. Excluded from this first patch:
unrelated Android changes, major Live TV rewrites, new trackers, volume boost,
thumbnail decoding and renderer/decoder rewrites. They need independent review
and would increase the regression surface.

Evidence boundaries: source inspection and published changelogs only so far.
Closed-as-stale issues are not assumed fixed. Android reports are not asserted
to reproduce on iOS. There is no exhaustive review sample or measured speedup.

The GPL upstream and Enhanced sources are reused with attribution. Replica's
recon/feedback/diff method is adapted to source reuse rather than clean-room
reimplementation. No playback sources, accounts, premium entitlements or
copyrighted media catalog are bundled or provided.
