# ThandoSign — Supabase backend setup

The app stores data on the device (SQLite) and syncs to Supabase when
online. These steps create the hosted backend. Free tier is enough.

## 1. Create the project

1. Go to https://supabase.com → **Start your project** → sign in (GitHub works).
2. **New organization** (if asked) → **New project**.
3. Name: `thandosign` (anything works). Set a database password and save it.
   Pick the region closest to you. Wait ~2 minutes for provisioning.

## 2. Create the tables + security policies

1. In the project dashboard, open **SQL Editor** → **New query**.
2. Paste the whole contents of [`schema.pgsql`](./schema.pgsql) → **Run**.
3. You should see "Success". Verify under **Table Editor** — five tables:
   `profiles`, `gestures`, `translations`, `system_logs`, `gesture_samples`.

## 3. Turn off email confirmation

The app signs in with email + password and does not send verification
emails, so confirmations must be off:

**Authentication → Sign In / Providers → Email** → untick **Confirm email**
→ Save.

(If you later want real email verification, re-enable this and add a
verification flow in the app.)

## 4. Connect the app

1. Dashboard → **Project Settings** (gear) → **Data API** (or **API**).
2. Copy:
   - **Project URL** — `https://<ref>.supabase.co`
   - **anon public** key (the `anon` / `public` key — safe to ship in the app;
     never use the `service_role` key, it bypasses row-level security).
3. Put them in `assets/.env`:

   ```
   SUPABASE_URL=https://<ref>.supabase.co
   SUPABASE_ANON_KEY=<anon key>
   ```

4. `flutter run` — sync activates automatically. The admin console's
   **Sync** card shows the pending count, last-sync time, and the exact
   reason when sync can't run.

## 5. Make yourself admin

The app seeds a local admin (`ngwenyathando@gmail.com` / `Admin123`).
Signing in with it while online auto-creates the server account and
pushes `role = admin` to `profiles` — no manual step needed for that
account. To make any *other* account an admin:

1. Have them register in the app (while online).
2. Dashboard → **Table Editor → `profiles`** → find their row → set
   `role` = `admin` → save.

## How sync works

- Writes go to local SQLite immediately, then queue in `pending_sync` and
  upload in order when the device is online and signed in.
- Only the signed-in account's own rows upload — translation history
  queued under a different account stays on the device until that user
  signs in again.
- Gesture dataset and user profiles also **pull down** on app start/login,
  so an admin edit on one device reaches the others. Remote gesture
  deletes propagate too, and pulls fetch any missing gesture illustrations
  in the background.
- `gestures` is also published to **Supabase Realtime** (the `do $$` block
  at the end of `schema.pgsql`), so dataset changes appear live on every
  signed-in device — profiles, translations, logs and samples are
  sync-cycle only, not realtime. If you ran the schema before this block
  was added, re-run the whole file once — it's idempotent.
- Camera frames are never uploaded — only text/metadata rows.
- **Cloud sync** can be switched off per device in Admin → Settings; the
  app then behaves exactly like the offline-only build.
- A public-read **`gesture-images` storage bucket** holds AI-generated
  sign illustrations. Admins generate (or regenerate) images in the app;
  they upload to the bucket and every device downloads them. Only admins
  can write objects — reads are public so even signed-out devices can
  fetch illustrations.

## One-time maintenance (existing deployments)

If the project was created before the case-insensitive label index
existed, duplicate gesture rows (e.g. 'Father' vs 'father') may already
be on the server — they cause the visible dataset flicker and inflated
counts (e.g. 306 instead of 187):

1. SQL Editor → paste [`dedupe_gestures.sql`](./dedupe_gestures.sql) →
   **Run** (it previews, deletes duplicates, then adds the protection
   index itself).
2. Re-run [`schema.pgsql`](./schema.pgsql) once — it's idempotent.

## Troubleshooting sync

- The Sync card (**Admin → Settings**) names the exact reason sync can't
  run ("No network connection detected", "No cloud session", …) — read it
  first.
- A **local sign-in is offline-only** — it verifies against the device's
  SQLite copy, not Supabase Auth. Accounts created or signed in while
  offline never get a cloud session until you **sign out and sign back in
  while online** (that provisions the cloud account and starts the
  session sync needs).
- If the card reports an email-confirmation error, re-check step 3 —
  **Confirm email must be off**, or confirm the account's email first.
- `pending_sync` rows that fail 5 upload attempts are dropped and noted
  in **Logs** (`sync_drop`) — check the error there.

## Limitations

- Admin "delete user" deactivates the `profiles` row (`is_active=false`).
  Removing the account from Supabase Auth entirely requires the service
  role key (server-side) — intentionally not shipped in the app.
- Row Level Security is on; if queries ever return empty unexpectedly,
  check **Authentication** shows a signed-in user and the policies above
  were applied.
