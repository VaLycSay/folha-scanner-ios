import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const root = path.resolve(process.argv[2] ?? 'upstream');
const reportDir = path.resolve(process.argv[3] ?? 'reports');
const files = new Map();
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
async function edit(relative, before, after, count = 1) {
  let file = files.get(relative);
  if (!file) {
    const original = await fs.readFile(path.join(root, relative));
    file = {original, text: original.toString('utf8').replaceAll('\r\n', '\n')};
    files.set(relative, file);
  }
  const matches = file.text.split(before).length - 1;
  if (matches !== count) throw Error(`${relative}: expected ${count} anchors, got ${matches}`);
  file.text = file.text.replaceAll(before, after);
}

const player = 'composeApp/src/commonMain/kotlin/com/nuvio/app/features/player/';
const bridge = 'iosApp/iosApp/Player/MPVPlayerBridge.swift';
const pip = 'iosApp/iosApp/Player/PlayerPictureInPictureController.swift';

// Adapted from Enhanced acb4383: keep upstream audio mixing policy and MPV.
await edit(bridge, `    private func activateAudioSessionForPlayback() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[NowPlaying] Failed to activate audio session: \\(error)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[NowPlaying] Failed to deactivate audio session: \\(error)")
        }
    }`, `    // Serialize activation/deactivation across player instances without blocking UI.
    private static let audioSessionQueue = DispatchQueue(label: "nuvio.audio-session", qos: .userInitiated)

    private func activateAudioSessionForPlayback() {
        Self.audioSessionQueue.async {
            do {
                let session = AVAudioSession.sharedInstance()
                if session.category != .playback || session.mode != .moviePlayback ||
                    session.categoryOptions != [.mixWithOthers] {
                    try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                }
                try session.setActive(true)
            } catch {
                print("[NowPlaying] Failed to activate audio session: \\(error)")
            }
        }
    }

    private func deactivateAudioSession() {
        Self.audioSessionQueue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("[NowPlaying] Failed to deactivate audio session: \\(error)")
            }
        }
    }`);

// Preserve an explicitly paused video across a non-PiP background round-trip.
await edit(bridge, `    @objc private func enterBackground() {
        guard mpv != nil else { return }
        if pictureInPictureController?.enteredBackground() == true { return }`, `    private var resumePlaybackAfterBackground = false

    @objc private func enterBackground() {
        guard mpv != nil else { return }
        resumePlaybackAfterBackground = isPlayerPlaying
        if pictureInPictureController?.enteredBackground() == true { return }`);
await edit(bridge, `        let wasInPictureInPicture = pictureInPictureController?.enteredForeground() == true
        if wasInPictureInPicture { return }
        setStringProperty("vid", "auto")
        playPlayback()`, `        let wasInPictureInPicture = pictureInPictureController?.enteredForeground() == true
        let shouldResume = resumePlaybackAfterBackground
        resumePlaybackAfterBackground = false
        if wasInPictureInPicture { return }
        setStringProperty("vid", "auto")
        if shouldResume { playPlayback() }`);

// Compatible PiP state fix from Enhanced 4b435d6; no renderer/decoder replacement.
await edit(pip, '    private var stopRequested = false\n', '    private var stopRequested = false\n    private var systemStartInProgress = false\n');
await edit(pip, `        let preservePlaybackState = keepsPlaybackAlive || hasPresentedPictureInPicture || controller?.isPictureInPictureActive == true
        hasPresentedPictureInPicture = false`, `        let preservePlaybackState = keepsPlaybackAlive || hasPresentedPictureInPicture || controller?.isPictureInPictureActive == true
        if isStarting, !systemStartInProgress, controller?.isPictureInPictureActive != true {
            isStarting = false
        }
        hasPresentedPictureInPicture = false`);
await edit(pip, `        isStarting = true
        metalLayer?.nuvioPiPConsumesVideo = true`, `        isStarting = true
        systemStartInProgress = true
        metalLayer?.nuvioPiPConsumesVideo = true`);
await edit(pip, `        isStarting = false
        isActive = true`, `        isStarting = false
        systemStartInProgress = false
        isActive = true`);
await edit(pip, `        isStarting = false
        isActive = false
        stopRequested = false`, `        isStarting = false
        systemStartInProgress = false
        isActive = false
        stopRequested = false`, 2);

// Adapted from Enhanced ac1b6ed, including both original control layouts.
await edit(player + 'PlayerTimeline.kt', 'import androidx.compose.runtime.CompositionLocalProvider\n', 'import androidx.compose.runtime.CompositionLocalProvider\nimport androidx.compose.runtime.DisposableEffect\nimport androidx.compose.runtime.LaunchedEffect\nimport androidx.compose.runtime.rememberUpdatedState\n');
await edit(player + 'PlayerTimeline.kt', '@OptIn(ExperimentalMaterial3Api::class)\n@Composable\ninternal fun PlayerTimeline(', `@Composable
internal fun ReportTimelineTouch(touching: Boolean, onTouchChange: (Boolean) -> Unit) {
    val latestOnTouchChange by rememberUpdatedState(onTouchChange)
    LaunchedEffect(touching) { latestOnTouchChange(touching) }
    DisposableEffect(Unit) {
        onDispose { latestOnTouchChange(false) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PlayerTimeline(`);
await edit(player + 'PlayerTimeline.kt', '    enabled: Boolean = true,\n) {', '    enabled: Boolean = true,\n    onTouchChange: (Boolean) -> Unit = {},\n) {');
await edit(player + 'PlayerTimeline.kt', '    val isInteracting = enabled && durationMs > 0L && (isPressed || isDragged)\n', '    val isInteracting = enabled && durationMs > 0L && (isPressed || isDragged)\n    ReportTimelineTouch(isInteracting, onTouchChange)\n');

await edit(player + 'PlayerControls.kt', 'package com.nuvio.app.features.player\n', 'package com.nuvio.app.features.player\n\nimport androidx.compose.foundation.interaction.MutableInteractionSource\nimport androidx.compose.foundation.interaction.collectIsDraggedAsState\nimport androidx.compose.foundation.interaction.collectIsPressedAsState\n');
await edit(player + 'PlayerControls.kt', `    horizontalSafePadding: androidx.compose.ui.unit.Dp,
    modifier: Modifier = Modifier,
) {`, `    horizontalSafePadding: androidx.compose.ui.unit.Dp,
    modifier: Modifier = Modifier,
    onTimelineTouchChange: (Boolean) -> Unit = {},
) {`);
await edit(player + 'PlayerControls.kt', '                ProgressControls(\n', '                ProgressControls(\n                    onTimelineTouchChange = onTimelineTouchChange,\n');
await edit(player + 'PlayerControls.kt', '                    PlayerTimeline(\n', '                    PlayerTimeline(\n                        onTouchChange = onTimelineTouchChange,\n');
await edit(player + 'PlayerControls.kt', `    onEpisodesClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {`, `    onEpisodesClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    onTimelineTouchChange: (Boolean) -> Unit = {},
) {`);
await edit(player + 'PlayerControls.kt', '        PlayerSeekBar(\n', '        PlayerSeekBar(\n            onTouchChange = onTimelineTouchChange,\n');
await edit(player + 'PlayerControls.kt', `internal fun PlayerSeekBar(
    durationMs: Long,
    displayedPositionMs: Long,
    metrics: PlayerLayoutMetrics,
    onScrubChange: (Long) -> Unit,
    onScrubFinished: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {`, `internal fun PlayerSeekBar(
    durationMs: Long,
    displayedPositionMs: Long,
    metrics: PlayerLayoutMetrics,
    onScrubChange: (Long) -> Unit,
    onScrubFinished: (Long) -> Unit,
    modifier: Modifier = Modifier,
    onTouchChange: (Boolean) -> Unit = {},
) {`);
await edit(player + 'PlayerControls.kt', `    val seekDescription = stringResource(Res.string.player_seek_position)
    Column(modifier = modifier) {
        Slider(`, `    val seekDescription = stringResource(Res.string.player_seek_position)
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val isDragged by interactionSource.collectIsDraggedAsState()
    ReportTimelineTouch(durationMs > 0L && (isPressed || isDragged), onTouchChange)
    Column(modifier = modifier) {
        Slider(
            interactionSource = interactionSource,`);
await edit(player + 'PlayerScreenRuntimeState.kt', '    var isScrubbingTimeline by mutableStateOf(false)\n', '    var isScrubbingTimeline by mutableStateOf(false)\n    var isTouchingTimeline by mutableStateOf(false)\n');
await edit(player + 'PlayerScreenRuntimeEffects.kt', '        isScrubbingTimeline = false\n', '        isScrubbingTimeline = false\n        isTouchingTimeline = false\n');
await edit(player + 'PlayerScreenRuntimeEffects.kt', '        controlsActivityTick,\n        isScrubbingTimeline,\n', '        controlsActivityTick,\n        isScrubbingTimeline,\n        isTouchingTimeline,\n');
await edit(player + 'PlayerScreenRuntimeEffects.kt', '            isScrubbingTimeline ||\n            !playbackSnapshot.isPlaying', '            isScrubbingTimeline ||\n            isTouchingTimeline ||\n            !playbackSnapshot.isPlaying');
await edit(player + 'PlayerScreenRuntimeUi.kt', `                scheduleProgressSyncAfterSeek()
            },
            horizontalSafePadding = horizontalSafePadding,`, `                scheduleProgressSyncAfterSeek()
            },
            onTimelineTouchChange = { touching -> isTouchingTimeline = touching },
            horizontalSafePadding = horizontalSafePadding,`);

// All anchors have matched before the first source write. Never silently port
// a patch to a different upstream version.
const changes = [];
for (const [relative, file] of files) {
  const updated = Buffer.from(file.text);
  await fs.writeFile(path.join(root, relative), updated);
  changes.push({path: relative, before_sha256: hash(file.original), after_sha256: hash(updated)});
}
await fs.mkdir(reportDir, {recursive: true});
await fs.writeFile(path.join(reportDir, 'changes.json'), JSON.stringify({
  official_commit: '6d435785c0e082ae3d4fbb8152e1ff5e45c2e575',
  official_version: '0.5.10-beta',
  enhanced_sources: ['acb4383fa9c9d568b116b08fa89275dfc8d07856', '4b435d6525bd3017b39655f51344765d075abc5f', 'ac1b6ed69376b37ee1612b87f4ee9f5b4ee79026'],
  changes, status: 'applied-not-runtime-validated'
}, null, 2) + '\n');
console.log(`Applied focused upgrades to ${changes.length} files; native engines and feature policies unchanged.`);
