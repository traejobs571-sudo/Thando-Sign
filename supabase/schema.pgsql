-- ThandoSign Supabase schema
-- Run this in the Supabase SQL editor (Dashboard → SQL → New query).
-- Creates the five app tables plus row-level-security policies.
-- Re-runnable: uses IF NOT EXISTS / OR REPLACE throughout.

-- ---------------------------------------------------------------- tables

create table if not exists public.profiles (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  name text not null default '',
  role text not null default 'user' check (role in ('user', 'admin')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.gestures (
  uuid uuid primary key default gen_random_uuid(),
  label text unique not null,
  meaning text not null default '',
  category text not null default 'General',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Gesture illustrations (AI-generated, stored in the gesture-images
-- bucket). Column is separate so re-running this file on an older schema
-- still adds it.
alter table public.gestures add column if not exists image_url text;

-- Case-insensitive label uniqueness. The `label unique` constraint above
-- is case-SENSITIVE in Postgres, so 'Father' and 'father' could coexist —
-- duplicate label rows make every client flap between conflicting states.
-- If this statement fails, duplicate labels already exist: run
-- dedupe_gestures.sql first, then re-run this file.
create unique index if not exists gestures_label_lower_key
  on public.gestures (lower(label));

create table if not exists public.translations (
  uuid uuid primary key,
  user_email text,
  input_type text not null default 'gesture',
  input_label text not null default '',
  translated_text text not null default '',
  confidence real not null default 0,
  source text not null default 'gemini',
  created_at timestamptz not null default now()
);

create table if not exists public.system_logs (
  uuid uuid primary key,
  user_email text,
  action text not null,
  details text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.gesture_samples (
  uuid uuid primary key,
  label text not null,
  landmarks jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists translations_user_email_idx
  on public.translations (user_email);
create index if not exists system_logs_created_idx
  on public.system_logs (created_at desc);
create index if not exists gesture_samples_label_idx
  on public.gesture_samples (label);

-- ------------------------------------------------------------ admin check

-- True when the signed-in user's profile row is an admin. SECURITY DEFINER
-- so policies can read profiles without granting broad select access.
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles
    where email = auth.email() and role = 'admin' and is_active
  );
$$;

-- ------------------------------------------------------------------- rls

alter table public.profiles enable row level security;
alter table public.gestures enable row level security;
alter table public.translations enable row level security;
alter table public.system_logs enable row level security;
alter table public.gesture_samples enable row level security;

-- profiles: users see their own row; admins see and manage all rows.
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated
  using (email = auth.email() or public.is_admin());

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check (email = auth.email() or public.is_admin());

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update to authenticated
  using (email = auth.email() or public.is_admin())
  with check (email = auth.email() or public.is_admin());

-- Deleting a profile row hides the account from the app; the auth.users
-- row itself can only be removed with the service key (not shipped in app).
drop policy if exists profiles_delete_admin on public.profiles;
create policy profiles_delete_admin on public.profiles
  for delete to authenticated
  using (public.is_admin());

-- gestures: readable by everyone signed in; writable by admins.
drop policy if exists gestures_select on public.gestures;
create policy gestures_select on public.gestures
  for select to authenticated using (true);

drop policy if exists gestures_write_admin on public.gestures;
create policy gestures_write_admin on public.gestures
  for insert to authenticated with check (public.is_admin());

drop policy if exists gestures_update_admin on public.gestures;
create policy gestures_update_admin on public.gestures
  for update to authenticated using (public.is_admin());

drop policy if exists gestures_delete_admin on public.gestures;
create policy gestures_delete_admin on public.gestures
  for delete to authenticated using (public.is_admin());

-- translations: users insert their own, read their own; admins read all.
drop policy if exists translations_insert on public.translations;
create policy translations_insert on public.translations
  for insert to authenticated
  with check (user_email = auth.email() or public.is_admin());

drop policy if exists translations_select on public.translations;
create policy translations_select on public.translations
  for select to authenticated
  using (user_email = auth.email() or public.is_admin());

-- system_logs: any signed-in user appends; only admins read/clear.
drop policy if exists logs_insert on public.system_logs;
create policy logs_insert on public.system_logs
  for insert to authenticated with check (true);

drop policy if exists logs_select_admin on public.system_logs;
create policy logs_select_admin on public.system_logs
  for select to authenticated using (public.is_admin());

drop policy if exists logs_delete_admin on public.system_logs;
create policy logs_delete_admin on public.system_logs
  for delete to authenticated using (public.is_admin());

-- gesture_samples: readable by all; written by admins (sample capture is
-- an admin-only feature in the app).
drop policy if exists samples_select on public.gesture_samples;
create policy samples_select on public.gesture_samples
  for select to authenticated using (true);

drop policy if exists samples_write_admin on public.gesture_samples;
create policy samples_write_admin on public.gesture_samples
  for insert to authenticated with check (public.is_admin());

-- Realtime: publish gesture changes so every signed-in device receives
-- live dataset updates. Idempotent — safe to re-run this whole file.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'gestures'
  ) then
    alter publication supabase_realtime add table public.gestures;
  end if;
end $$;

-- ------------------------------------------------------ gesture images
-- Public-read bucket for AI-generated sign illustrations. Anyone (even
-- signed-out devices) can download; only admins can upload/replace —
-- the app generates images once per gesture and shares them everywhere.
insert into storage.buckets (id, name, public)
values ('gesture-images', 'gesture-images', true)
on conflict (id) do nothing;

drop policy if exists gesture_images_select on storage.objects;
create policy gesture_images_select on storage.objects
  for select using (bucket_id = 'gesture-images');

drop policy if exists gesture_images_admin_write on storage.objects;
create policy gesture_images_admin_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'gesture-images' and public.is_admin());

drop policy if exists gesture_images_admin_update on storage.objects;
create policy gesture_images_admin_update on storage.objects
  for update to authenticated
  using (bucket_id = 'gesture-images' and public.is_admin());

drop policy if exists gesture_images_admin_delete on storage.objects;
create policy gesture_images_admin_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'gesture-images' and public.is_admin());
