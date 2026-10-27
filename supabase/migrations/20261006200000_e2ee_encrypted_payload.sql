-- Zero-Knowledge End-to-End Encryption (issue #245).
--
-- Adds support for encrypted envelopes across sync tables and introduces
-- `user_e2ee_settings` for storing KDF parameters (salt, algorithm, key check tag).
-- Server and database administrators cannot read transcripts, titles, summaries,
-- notes, tags, or media blobs; clients encrypt before push and decrypt after pull.

-- ---------------------------------------------------------------------------
-- 1. Encrypted payload columns for existing user-owned sync tables
-- ---------------------------------------------------------------------------

alter table public.recordings
  add column if not exists encrypted_payload text;

alter table public.segments
  add column if not exists encrypted_payload text;

alter table public.clipboard_items
  add column if not exists encrypted_payload text;

alter table public.projects
  add column if not exists encrypted_payload text;

-- ---------------------------------------------------------------------------
-- 2. user_e2ee_settings — client-side KDF parameters and key verification
-- ---------------------------------------------------------------------------

create table if not exists public.user_e2ee_settings (
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kdf_salt text not null,
  kdf_algorithm text not null default 'pbkdf2_sha256',
  key_check_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (owner_id)
);

revoke all on table public.user_e2ee_settings from public, anon, authenticated;
grant select, insert, update on table public.user_e2ee_settings to authenticated;

alter table public.user_e2ee_settings enable row level security;
alter table public.user_e2ee_settings force row level security;

create policy user_e2ee_settings_select_own on public.user_e2ee_settings
  for select to authenticated
  using (owner_id = (select auth.uid()));

create policy user_e2ee_settings_insert_own on public.user_e2ee_settings
  for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy user_e2ee_settings_update_own on public.user_e2ee_settings
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create trigger user_e2ee_settings_reject_owner_change
  before update on public.user_e2ee_settings
  for each row execute function public.reject_owner_change();

create trigger user_e2ee_settings_touch_updated_at
  before insert or update on public.user_e2ee_settings
  for each row execute function public.touch_updated_at();
