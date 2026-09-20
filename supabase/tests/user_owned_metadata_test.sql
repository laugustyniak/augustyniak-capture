-- pgTAP: the ownership guarantees of the user-owned metadata schema (#190).
-- Run with `supabase test db`. Everything happens inside one transaction that
-- is rolled back, so the seeded users never outlive the test.

begin;

select plan(29);

-- Two accounts. Local GoTrue needs nothing beyond id + email to make these
-- rows valid targets for the `owner_id` foreign key.
insert into auth.users (id, email)
values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@example.com');

-- Impersonate a signed-in user the way PostgREST does: the `authenticated`
-- role plus a JWT claims setting that `auth.uid()` reads `sub` from.
create function pg_temp.sign_in(uid uuid) returns void
language sql
as $$
  select set_config('role', 'authenticated', true);
  select set_config(
    'request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text,
    true);
$$;

create function pg_temp.sign_out() returns void
language sql
as $$
  select set_config('role', 'postgres', true);
  select set_config('request.jwt.claims', '', true);
$$;

-- ---------------------------------------------------------------------------
-- Every table has RLS enabled and forced.
-- ---------------------------------------------------------------------------

select is(
  (select count(*) from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('projects', 'recordings', 'segments', 'clipboard_items',
                        'revisions', 'devices', 'sync_state')
      and c.relrowsecurity and c.relforcerowsecurity),
  7::bigint,
  'RLS is enabled and forced on all seven tables');

-- ---------------------------------------------------------------------------
-- User A writes one row of everything; owner_id defaults to A.
-- ---------------------------------------------------------------------------

select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');

select lives_ok($$
  insert into public.projects (id, name, color_hex, created_at)
  values ('proj-a', 'Project A', '#112233', now())
$$, 'A inserts a project');

select lives_ok($$
  insert into public.recordings
    (id, file_path, duration_ms, type, status, created_at, project_id,
     updated_at)
  values ('rec-a', 'rec-a.m4a', 1000, 'audioRecording', 'completed', now(),
          'proj-a', '2000-01-01')
$$, 'A inserts a recording bound to A''s project');

select lives_ok($$
  insert into public.segments
    (recording_id, index, file_path, type, created_at, duration_ms, size_bytes)
  values ('rec-a', 0, 'rec-a.m4a', 'audioRecording', now(), 1000, 42)
$$, 'A inserts segment 0');

select lives_ok($$
  insert into public.clipboard_items (id, type, text, copied_at)
  values ('clip-a', 'text', 'hello', now())
$$, 'A inserts a clipboard item');

select lives_ok($$
  insert into public.revisions (id, recording_id, at, field, to_value, source)
  values ('rev-a', 'rec-a', now(), 'title', 'First', 'user')
$$, 'A inserts a revision');

select lives_ok($$
  insert into public.devices (id, name, platform)
  values ('dev-a', 'Desk', 'linux')
$$, 'A inserts a device');

select lives_ok($$
  insert into public.sync_state (device_id, table_name, pulled_through)
  values ('dev-a', 'recordings', now())
$$, 'A inserts sync state');

select is(
  (select owner_id from public.recordings where id = 'rec-a'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'owner_id defaults to auth.uid()');

-- ---------------------------------------------------------------------------
-- User B sees none of it and can reach none of it.
-- ---------------------------------------------------------------------------

select pg_temp.sign_in('22222222-2222-2222-2222-222222222222');

select is((select count(*) from public.projects), 0::bigint,
  'B sees no projects');
select is((select count(*) from public.recordings), 0::bigint,
  'B sees no recordings');
select is((select count(*) from public.segments), 0::bigint,
  'B sees no segments');
select is((select count(*) from public.clipboard_items), 0::bigint,
  'B sees no clipboard items');
select is((select count(*) from public.revisions), 0::bigint,
  'B sees no revisions');
select is((select count(*) from public.devices), 0::bigint,
  'B sees no devices');
select is((select count(*) from public.sync_state), 0::bigint,
  'B sees no sync state');

select throws_ok($$
  insert into public.recordings
    (id, owner_id, file_path, duration_ms, type, status, created_at)
  values ('rec-b-forged', '11111111-1111-1111-1111-111111111111',
          'x.m4a', 1, 'audioRecording', 'saved', now())
$$, '42501', null,
  'B cannot insert a row owned by A');

select throws_ok($$
  insert into public.segments
    (recording_id, index, file_path, type, created_at, duration_ms, size_bytes)
  values ('rec-a', 1, 'x.m4a', 'audioRecording', now(), 1, 1)
$$, '23503', null,
  'B cannot attach a segment to A''s recording');

select throws_ok($$
  insert into public.recordings
    (id, file_path, duration_ms, type, status, created_at, project_id)
  values ('rec-b', 'rec-b.m4a', 1, 'audioRecording', 'saved', now(), 'proj-a')
$$, '23503', null,
  'B cannot bind a recording to A''s project');

-- A blocked update is not an error under RLS; it simply matches nothing.
select lives_ok($$
  update public.recordings set title = 'stolen' where id = 'rec-a'
$$, 'B''s update of A''s recording is silently ignored');

select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');
select is(
  (select title from public.recordings where id = 'rec-a'),
  null,
  'B''s update of A''s recording changed nothing');
select pg_temp.sign_in('22222222-2222-2222-2222-222222222222');

-- ---------------------------------------------------------------------------
-- Even the owner cannot hand a row over, hard-delete it or edit history.
-- ---------------------------------------------------------------------------

select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');

select throws_ok($$
  update public.recordings
     set owner_id = '22222222-2222-2222-2222-222222222222'
   where id = 'rec-a'
$$, '23514', 'owner_id is immutable',
  'owner_id cannot be changed on update');

select throws_ok($$
  delete from public.recordings where id = 'rec-a'
$$, '42501', null,
  'hard delete is not granted — removal is a tombstone');

select throws_ok($$
  update public.revisions set to_value = 'edited' where id = 'rev-a'
$$, '42501', null,
  'revisions are append-only');

select lives_ok($$
  update public.recordings
     set title = 'Renamed', deleted_at = now()
   where id = 'rec-a'
$$, 'the owner edits and tombstones a recording');

select is(
  (select version from public.recordings where id = 'rec-a'),
  1::bigint,
  'the server does not bump version — the client owns it');

select ok(
  (select updated_at > '2000-01-01' from public.recordings where id = 'rec-a'),
  'updated_at is touched on update');

-- ---------------------------------------------------------------------------
-- anon gets a permission error, never an empty result.
-- ---------------------------------------------------------------------------

select pg_temp.sign_out();
select set_config('role', 'anon', true);

select throws_ok($$ select count(*) from public.recordings $$, '42501', null,
  'anon cannot read recordings');
select throws_ok($$ select count(*) from public.projects $$, '42501', null,
  'anon cannot read projects');

select pg_temp.sign_out();

select * from finish();

rollback;
