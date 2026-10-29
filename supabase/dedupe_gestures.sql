-- One-shot cleanup for duplicate gesture labels (case-insensitive).
-- Run this in the Supabase SQL editor (Dashboard → SQL → New query)
-- BEFORE re-running the updated schema.pgsql.
--
-- Why duplicates happen: multiple devices could push the same label under
-- different uuids (e.g. 'Father' vs 'father') — Postgres UNIQUE is
-- case-sensitive, so both rows were allowed. Every sync pass then rewrote
-- client state from whichever duplicate came last: the visible
-- "on/off/on/off" flicker and inflated counts (e.g. 306 instead of 187).

-- ── Step 1: preview the damage ────────────────────────────────────────
select lower(label) as label_key, count(*) as rows_per_label
from public.gestures
group by 1
having count(*) > 1
order by 2 desc;

-- ── Step 2: keep the best row per label, delete the rest ──────────────
-- Winner preference: a row that has an illustration, then the most
-- recently updated, then the earliest created.
delete from public.gestures g
using (
  select uuid,
         row_number() over (
           partition by lower(label)
           order by
             (image_url is not null and image_url <> '') desc,
             updated_at desc,
             created_at asc
         ) as rn
  from public.gestures
) ranked
where g.uuid = ranked.uuid
  and ranked.rn > 1;

-- ── Step 3: verify ───────────────────────────────────────────────────
-- Should return 0 rows:
select lower(label) as label_key, count(*)
from public.gestures
group by 1
having count(*) > 1;

-- ── Step 4: make future duplicates impossible ────────────────────────
create unique index if not exists gestures_label_lower_key
  on public.gestures (lower(label));
