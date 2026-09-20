-- User-owned metadata for cloud sync (issue #187, slice 2 — #190).
--
-- Local SQLite and local source files remain authoritative for offline
-- capture; these tables only define what a signed-in account may hold in the
-- cloud. Column names mirror `lib/core/database/app_database.dart`, and ids are
-- `text` because the client generates them (uuid v4 strings for recordings and
-- clipboard items, legacy free-form strings for projects).
--
-- Ownership is derived from the verified session: `owner_id` defaults to
-- `auth.uid()`, every policy checks it, and a trigger refuses to move a row to
-- another owner. Every primary key is `(owner_id, id)`, never `id` alone: a
-- global key would let one user squat an id another user later needs, and the
-- duplicate-key error would confirm that a stranger's row exists. Every child
-- table references its parent through the same composite key, so a foreign-key
-- check can never confirm another user's row either.
--
-- Deletes are tombstones. `authenticated` is granted no `delete` at all — a row
-- leaves the cloud by setting `deleted_at`, which is what the outbox/inbox sync
-- (slice 3) propagates. `version` is carried by the client and compared by
-- slice 3; nothing here bumps it, because a server-side bump would race the
-- client's own conflict detection. `updated_at` is the opposite: the server
-- stamps it on insert and on update and ignores whatever the client sent, so a
-- client cannot backdate a row past a pull cursor. (It is transaction-start
-- time; whether a cursor can rely on it under concurrent pushes is slice 3's
-- question, not this file's promise.)

-- ---------------------------------------------------------------------------
-- Shared trigger functions
-- ---------------------------------------------------------------------------

create or replace function public.reject_owner_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.owner_id is distinct from old.owner_id then
    raise exception 'owner_id is immutable'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

-- Fires on insert as well as update, so a client cannot backdate a row past a
-- pull cursor by supplying its own `updated_at`.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.reject_owner_change() from public, anon;
revoke all on function public.touch_updated_at() from public, anon;

-- ---------------------------------------------------------------------------
-- projects
-- ---------------------------------------------------------------------------

-- `Project` in Dart has no colour or creation time; the SQLite mirror carries
-- both from a legacy schema and invents them. Here they are optional so the
-- sync client never has to.
create table public.projects (
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  name text not null,
  color_hex text,
  repository_path text,
  created_at timestamptz not null default now(),
  payload jsonb,
  version bigint not null default 1,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (owner_id, id)
);

-- ---------------------------------------------------------------------------
-- recordings — the parent row of a capture; segment 0 is described by
-- file_path / size_bytes / content_hash exactly, as in the archive contract.
-- ---------------------------------------------------------------------------

create table public.recordings (
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  file_path text not null,
  duration_ms integer not null,
  size_bytes bigint not null default 0,
  content_hash text,
  type text not null,
  status text not null,
  source_mime_type text,
  transcript text,
  category text,
  title text,
  summary text,
  tags jsonb not null default '[]'::jsonb,
  created_at timestamptz not null,
  is_processed_by_user boolean not null default false,
  processed_at timestamptz,
  project_id text,
  failure_reason text,
  payload jsonb,
  version bigint not null default 1,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (owner_id, id),
  foreign key (owner_id, project_id)
    references public.projects (owner_id, id) on delete set null (project_id)
);

create index recordings_owner_created_at_idx
  on public.recordings (owner_id, created_at desc);

create index recordings_owner_updated_at_idx
  on public.recordings (owner_id, updated_at);

-- ---------------------------------------------------------------------------
-- segments — one row per source fragment; the unit of processing and retry.
-- ---------------------------------------------------------------------------

create table public.segments (
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  recording_id text not null,
  index integer not null check (index >= 0),
  file_path text not null,
  type text not null,
  source_mime_type text,
  created_at timestamptz not null,
  duration_ms integer not null,
  size_bytes bigint not null,
  content_hash text,
  text text,
  error text,
  version bigint not null default 1,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (owner_id, recording_id, index),
  foreign key (owner_id, recording_id)
    references public.recordings (owner_id, id) on delete cascade
);

-- ---------------------------------------------------------------------------
-- clipboard_items
-- ---------------------------------------------------------------------------

create table public.clipboard_items (
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  type text not null,
  text text,
  image_path text,
  copied_at timestamptz not null,
  preview text,
  collections jsonb not null default '[]'::jsonb,
  version bigint not null default 1,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (owner_id, id)
);

create index clipboard_items_owner_copied_at_idx
  on public.clipboard_items (owner_id, copied_at desc);

-- ---------------------------------------------------------------------------
-- revisions — append-only field history of a recording (`revisions.jsonl`).
-- `RecordingRevision` has no id of its own; its natural key is what makes a
-- retried push idempotent. That assumes `at` (`DateTime.now()` per row in
-- `capture_history.dart`) has enough resolution to tell two distinct edits of
-- one field apart from one edit pushed twice — slice 3 must verify the clock
-- on Windows before choosing between `insert` and `on conflict do nothing`.
-- Insert-only: no update grant, no version, no tombstone — history rides its
-- recording's `deleted_at`. `updated_at` is stamped on insert so a pull cursor
-- still works.
-- ---------------------------------------------------------------------------

create table public.revisions (
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  recording_id text not null,
  at timestamptz not null,
  field text not null,
  from_value text,
  to_value text,
  source text not null,
  updated_at timestamptz not null default now(),
  primary key (owner_id, recording_id, at, field),
  foreign key (owner_id, recording_id)
    references public.recordings (owner_id, id) on delete cascade
);

create index revisions_owner_updated_at_idx
  on public.revisions (owner_id, updated_at);

-- ---------------------------------------------------------------------------
-- devices — each install that has synced under this account.
-- ---------------------------------------------------------------------------

create table public.devices (
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  name text not null,
  platform text not null,
  app_version text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  version bigint not null default 1,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (owner_id, id)
);

-- ---------------------------------------------------------------------------
-- sync_state — per device, per table: how far that device has pulled.
-- ---------------------------------------------------------------------------

create table public.sync_state (
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  device_id text not null,
  table_name text not null,
  pulled_through timestamptz,
  pushed_through timestamptz,
  version bigint not null default 1,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (owner_id, device_id, table_name),
  foreign key (owner_id, device_id)
    references public.devices (owner_id, id) on delete cascade
);

-- ---------------------------------------------------------------------------
-- Grants, RLS and triggers — identical for every table.
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'projects', 'recordings', 'segments', 'clipboard_items',
    'revisions', 'devices', 'sync_state'
  ]
  loop
    -- Supabase's default privileges grant `all` to anon and authenticated the
    -- moment a table is created, so the revoke has to name authenticated too
    -- or `delete` survives underneath the narrower grant below.
    execute format(
      'revoke all on table public.%I from public, anon, authenticated', t);
    -- Revisions are append-only: no update grant, so an update is refused
    -- with a permission error rather than silently matching zero rows.
    if t = 'revisions' then
      execute format(
        'grant select, insert on table public.%I to authenticated', t);
    else
      execute format(
        'grant select, insert, update on table public.%I to authenticated', t);
    end if;

    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);

    execute format($p$
      create policy %1$s_select_own on public.%1$I
        for select to authenticated
        using (owner_id = (select auth.uid()))
    $p$, t);
    execute format($p$
      create policy %1$s_insert_own on public.%1$I
        for insert to authenticated
        with check (owner_id = (select auth.uid()))
    $p$, t);
    -- Revisions are append-only: no update policy, so an update is refused
    -- by RLS even though the grant exists for the loop's symmetry.
    if t <> 'revisions' then
      execute format($p$
        create policy %1$s_update_own on public.%1$I
          for update to authenticated
          using (owner_id = (select auth.uid()))
          with check (owner_id = (select auth.uid()))
      $p$, t);
    end if;

    execute format($p$
      create trigger %1$s_reject_owner_change
        before update on public.%1$I
        for each row execute function public.reject_owner_change()
    $p$, t);
    execute format($p$
      create trigger %1$s_touch_updated_at
        before insert or update on public.%1$I
        for each row execute function public.touch_updated_at()
    $p$, t);
  end loop;
end;
$$;
