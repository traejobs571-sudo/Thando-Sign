# Changelog

All notable changes to ThandoSign are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.3.0] — 2026-10-26

### Added

- **Conversation recording** — a red "Record session" button on the camera preview films a real `.mp4` (up to 30 s, auto-stop) while frames are sampled every ~300 ms. On stop, all sampled frames are sent to Gemini in a single request (`GeminiService.identifySigningSession`) and the complete signed message comes back as one transcript, saved to history as `input_type: 'recording'`.
- **Offline session fallback** — when the cloud is unreachable, each sampled frame is classified on-device and consecutive duplicate labels are collapsed into a rough transcript.
- **Compressed local replay** — the recorded clip is transcoded with `video_compress` into `documents/recordings/` (latest 5 retained) and replayable from the result card via a new `video_player`-based screen.
- **Front/back camera switching** — a flip-camera button on the preview swaps lenses in place via `CameraController.setDescription`; front-camera frames are horizontally mirrored so uploads and thumbnails match the mirrored preview. Disabled during recording and hidden on single-camera devices.
- **Frames-only fallback** — devices that cannot stream frames while recording video still get session translation (no saved clip).
- New unit tests for session-label de-duplication (`test/session_dedupe_test.dart`).

### Changed

- `GeminiService` generation config now accepts a per-request `maxOutputTokens` (raised to 1024 for session transcripts).
- Camera stream callback extracted into a shared `_onStreamFrame` method so the pipeline can be restored after recording or a lens switch.
- Privacy copy on the Home tab and in Settings clarified: live frames are never stored; recorded session clips stay on-device and are never uploaded.
- Dependencies: added `video_compress` and `video_player`.

### Fixed

- Serialized session start/stop transitions (`_sessionTransition`) so a fast re-tap cannot overlap an in-flight stop and consume the wrong frames.
- Guarded `notifyListeners` after controller disposal so in-flight async work can't crash.
- Recording can no longer start while a camera switch is in progress; `canSwitchCamera` also respects session transitions.
- All capture paths (`captureAndTranslate`, `captureToBatch`, `translateBatch`, `captureMotionBurst`) refuse to run during a session recording.
- Compressor output is verified to exist before replacing the raw capture.
- Status-chip row repositioned clear of the widened capture/record button row.

## Earlier versions

Feature history before 1.3.0 wasn't tracked in a changelog — see the README's feature list and project commit history (once version control is added) for prior releases.
