# ThandoSign — Real-Time ZSL Translator

A Flutter mobile application built for **Deaf Zimbabwe Trust (DZT)** that translates **Zimbabwe Sign Language (ZSL)** gestures into English text and speech in real time, powered by the **Google Gemini vision API**.

## Features

- **Hybrid sign-in / registration** — Supabase Auth online, local bcrypt accounts offline; accounts created offline provision to the cloud on the next online sign-in. Role-based access (user / admin), "remember me" sessions, forced rotation after an admin reset, and self-serve password reset via an on-screen 6-digit code (no mail backend)
- **Live camera translation** — capture a gesture, get text + spoken output. A bundled on-device hand-landmark model answers confident static signs instantly and escalates ambiguous frames to Gemini; when the cloud is unreachable it falls back to the on-device result
- **Multi-sign capture** — queue up to 10 frames (one per sign) and translate them in a single request, so fingerspelled words and multi-sign phrases come back as one combined result
- **Dynamic-sign capture** — record a ~2 s motion burst (8 frames) for signs that move (hello, come, go…); the cloud model reads the hand's path and shape change, and falls back to the on-device classifier on the final frame when offline
- **Conversation recording** — film up to 30 s of continuous signing and get the whole message translated in a single request; sampled frames go to Gemini once on stop, with a per-frame on-device fallback when offline. A compressed copy of the clip is kept on-device for replay (latest 5 retained)
- **Front/back camera switching** — flip between lenses on the live preview; front-camera frames are mirrored so uploads and thumbnails match what the user saw
- **Present mode** — fullscreen high-contrast view of the latest translation with the sign name, captured frame and how-to-sign steps, for showing a hearing person
- **Speech → sign mode** — speak and get step-by-step ZSL signing instructions
- **Vocabulary-constrained recognition** — Gemini answers anchored to a ~200-sign ZSL reference dataset (fingerspelling alphabet plus everyday words and phrases, incl. Zimbabwe-specific terms like *sadza* and *kombi*)
- **Auto-translate** — hands-free capture gated by on-device hand detection, so API quota is only spent when a sign is in frame; the interval is admin-tunable
- **On-device training** — admins record hand-landmark samples per gesture; a k-NN classifier learns the custom signs and recognises them fully offline
- **Text-to-speech** playback of translations (auto-speak toggle plus adjustable rate, pitch and volume, with a voice test)
- **Admin dashboard** — Overview (stats + sync health), Dataset (add/edit/delete, sample capture, image attach/regenerate), Users (roles, activation, resets), Logs (filter/search/clear), System settings (API key, recognition thresholds, sync toggle, registration switch, history retention & purge, data controls)
- **Reports** — analytics dashboard over a 7/30/90-day window: stat tiles, activity bar charts, recognition-source and input-type pie charts, top-signs ranking and per-user engagement, plus CSV export of translations, engagement, users and logs
- **Backup & restore** — full database export/import, admin-only
- **Server sync** — data pushes to Supabase when online; gestures and profiles also pull down to other devices, and the dataset updates **live via Realtime** while signed in
- **Speech → Sign with pictures** — spoken phrases produce per-word sign cards backed by **AI-generated gesture illustrations** (generated once per gesture, shared via a Supabase Storage bucket); names fall back to fingerspelling letter tiles. Every speech translation is recorded in history and syncs too

## Tech stack

- Flutter (Material 3, dark glass UI)
- `supabase_flutter` — hosted Postgres + Auth backend (optional — app works fully offline without it)
- `google_generative_ai` — Gemini vision for gesture recognition and sign illustrations (multi-model fallback chain)
- `camera` + `permission_handler` — live capture, video recording, lens switching and mic/camera permissions
- `video_compress` + `video_player` — compressed local copies of recorded sessions with in-app replay
- `tflite_flutter` — bundled hand-landmark model + k-NN from recorded samples
- `speech_to_text` — microphone input for speech → sign mode
- `flutter_tts` — speech output
- `sqflite` — local database (offline source of truth + sync outbox)
- `dbcrypt` + `flutter_secure_storage` — local password hashing and protected API-key storage
- `connectivity_plus` — Wi-Fi / mobile-data status
- `share_plus` + `file_selector` — backup/restore and CSV export
- `fl_chart` — admin analytics charts
- `flutter_dotenv` — bundled config via `assets/.env`
- `provider` + `go_router` — state & navigation

## Architecture — local-first, syncs when online

- **SQLite on device stays the source of truth** — every write lands locally and queues in a `pending_sync` outbox; the sync service uploads in order whenever the device is online and signed in.
- **Supabase stores the shared copy** — users, gestures, translation history, logs and training samples (see `supabase/SETUP.md`). Gesture and profile changes also pull down so admin edits reach every device.
- **Camera frames are never uploaded** — only text/metadata rows sync to the database, plus AI-generated illustration files in the `gesture-images` storage bucket. The only camera image that leaves the device goes to Google Gemini for recognition — and confident on-device results never leave the phone at all.
- Works on **Wi-Fi or mobile data**, and fully offline — the app watches connectivity and queues sync until it returns.

## Production build

1. Create a signing keystore (one-time):

   ```bash
   keytool -genkey -v -keystore C:\keys\thando-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias thando
   ```

2. Copy `android/key.properties.template` → `android/key.properties` and fill in the values (git-ignored).

3. Build:

   ```bash
   flutter build apk --release        # single APK
   flutter build appbundle --release  # Play Store bundle
   ```

Release builds are minified (R8) with resource shrinking, use HTTPS only (`usesCleartextTraffic="false"`), and request `CAMERA`, `RECORD_AUDIO` (speech → sign), `INTERNET`, and network/Wi-Fi-state permissions. The bundled `video_compress` plugin merges a legacy `WRITE_EXTERNAL_STORAGE` entry into the manifest — a no-op on Android 10+ (scoped storage); recorded session clips live only in the app's private documents directory.

## Setup

1. Get a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey).
2. Either:
   - put it in `assets/.env` (`GEMINI_API_KEY=...`), or
   - manage it in the app under **Admin dashboard → Settings → Gemini API key**.
3. (Optional) Set up the Supabase backend for cloud storage and cross-device
   sync — see [`supabase/SETUP.md`](supabase/SETUP.md), then add
   `SUPABASE_URL` and `SUPABASE_ANON_KEY` to `assets/.env`. Without these
   the app runs fully offline.
4. Run:

   ```bash
   flutter pub get
   flutter run
   flutter test   # unit + golden tests (optional)
   ```

5. On first launch you can register, or use the seeded admin account:

   - **ngwenyathando@gmail.com** / **Admin123**

## Notes

- Gemini's vision model identifies hand gestures from still frames. For production-grade ZSL accuracy, a dedicated model trained on a labelled ZSL dataset (e.g. MediaPipe + TensorFlow) is recommended alongside Gemini.
- Camera frames are sent to Google for recognition — see the in-app privacy notice.
- **Bundled tile imagery is ASL, not ZSL.** `assets/signs/` ships ~89
  American Sign Language photos/illustrations (Wikimedia Commons, see
  `assets/signs/ATTRIBUTION.md`) used as visual proxies — ZSL shares much
  of ASL's fingerspelling but has its own vocabulary, so source real ZSL
  assets before claiming ZSL accuracy. Labels without bundled art fall
  back to the captured-landmark skeleton, then an emoji/icon — admins can
  attach or generate images per gesture to close the gap.
- The seeded admin (`ngwenyathando@gmail.com` / `Admin123`) exists so a
  demo works out of the box — it's a well-known default password, so it
  **must be rotated before any real deployment**. Passwords reset by an
  admin (temporary passwords) are flagged `must_change_password` and force
  a change at the next sign-in.
