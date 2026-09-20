-- pgTAP: the ownership guarantees of the user-owned metadata schema (#190).
-- Run with `supabase test db`. Everything happens inside one transaction that
-- is rolled back, so the seeded users never outlive the test.
--
-- Every guarantee is asserted on every table, never on a representative one:
-- a policy dropped from a single table must turn this suite red.

begin;

select plan(66);

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

-- Runs a statement and answers how many rows it touched, because a
-- data-modifying CTE cannot sit inside a subquery.
create function pg_temp.affected(stmt text) returns bigint
language plpgsql
as $$
declare
  n bigint;
begin
  execute stmt;
  get diagnostics n = row_count;
  return n;
end;
$$;

create function pg_temp.sign_out() returns void
language sql
as $$
  select set_config('role', 'postgres', true);
  select set_config('request.jwt.claims', '', true);
$$;

-- One insert per table, parameterised by owner so both users can write the
-- same ids. Parents before children.
create function pg_temp.insert_everything(uid uuid) returns void
language plpgsql
as $$
begin
  perform pg_temp.sign_in(uid);
  insert into public.projects (id, name)
  values ('proj', 'Project');
  insert into public.recordings
    (id, file_path, duration_ms, type, status, created_at, project_id,
     updated_at)
  values ('rec', 'rec.m4a', 1000, 'audioRecording', 'completed', now(), 'proj',
          '2000-01-01');
  insert into public.segments
    (recording_id, index, file_path, type, created_at, duration_ms, size_bytes)
  values ('rec', 0, 'rec.m4a', 'audioRecording', now(), 1000, 42);
  insert into public.clipboard_items (id, type, text, copied_at)
  values ('clip', 'text', 'hello', now());
  insert into public.revisions (recording_id, at, field, to_value, source)
  values ('rec', '2026-01-01', 'title', 'First', 'user');
  insert into public.devices (id, name, platform)
  values ('dev', 'Desk', 'linux');
  insert into public.sync_state (device_id, table_name, pulled_through)
  values ('dev', 'recordings', now());
end;
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
-- A writes one row of everything; then B writes the same ids. A global key
-- would make B's insert fail with a duplicate — and tell B that A exists.
-- ---------------------------------------------------------------------------

select lives_ok(
  $$ select pg_temp.insert_everything('11111111-1111-1111-1111-111111111111') $$,
  'A inserts one row into every table');

select lives_ok(
  $$ select pg_temp.insert_everything('22222222-2222-2222-2222-222222222222') $$,
  'B inserts the same ids into every table — keys are owner-scoped');

-- ---------------------------------------------------------------------------
-- Each user reads exactly their own row of each table, owned by them.
-- ---------------------------------------------------------------------------

select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');

select is((select count(*) from public.projects), 1::bigint,
  'A reads one project');
select is((select count(*) from public.recordings), 1::bigint,
  'A reads one recording');
select is((select count(*) from public.segments), 1::bigint,
  'A reads one segment');
select is((select count(*) from public.clipboard_items), 1::bigint,
  'A reads one clipboard item');
select is((select count(*) from public.revisions), 1::bigint,
  'A reads one revision');
select is((select count(*) from public.devices), 1::bigint,
  'A reads one device');
select is((select count(*) from public.sync_state), 1::bigint,
  'A reads one sync state');

select is((select owner_id from public.projects),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'A''s project is owned by A — owner_id defaulted from auth.uid()');
select is((select owner_id from public.recordings),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'A''s recording is owned by A');
select is((select owner_id from public.segments),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'A''s segment is owned by A');
select is((select owner_id from public.clipboard_items),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'A''s clipboard item is owned by A');
select is((select owner_id from public.revisions),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'A''s revision is owned by A');
select is((select owner_id from public.devices),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'A''s device is owned by A');
select is((select owner_id from public.sync_state),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'A''s sync state is owned by A');

select pg_temp.sign_in('22222222-2222-2222-2222-222222222222');

select is((select count(*) from public.projects where owner_id <> auth.uid()),
  0::bigint, 'B sees none of A''s projects');
select is((select count(*) from public.recordings where owner_id <> auth.uid()),
  0::bigint, 'B sees none of A''s recordings');
select is((select count(*) from public.segments where owner_id <> auth.uid()),
  0::bigint, 'B sees none of A''s segments');
select is((select count(*) from public.clipboard_items where owner_id <> auth.uid()),
  0::bigint, 'B sees none of A''s clipboard items');
select is((select count(*) from public.revisions where owner_id <> auth.uid()),
  0::bigint, 'B sees none of A''s revisions');
select is((select count(*) from public.devices where owner_id <> auth.uid()),
  0::bigint, 'B sees none of A''s devices');
select is((select count(*) from public.sync_state where owner_id <> auth.uid()),
  0::bigint, 'B sees none of A''s sync state');

-- ---------------------------------------------------------------------------
-- B cannot write a row owned by A into any table.
-- ---------------------------------------------------------------------------

select throws_ok($$
  insert into public.projects (id, owner_id, name)
  values ('forged', '11111111-1111-1111-1111-111111111111', 'x')
$$, '42501', null, 'B cannot insert a project owned by A');
select throws_ok($$
  insert into public.recordings
    (id, owner_id, file_path, duration_ms, type, status, created_at)
  values ('forged', '11111111-1111-1111-1111-111111111111',
          'x.m4a', 1, 'audioRecording', 'saved', now())
$$, '42501', null, 'B cannot insert a recording owned by A');
select throws_ok($$
  insert into public.segments
    (owner_id, recording_id, index, file_path, type, created_at, duration_ms,
     size_bytes)
  values ('11111111-1111-1111-1111-111111111111', 'rec', 9, 'x.m4a',
          'audioRecording', now(), 1, 1)
$$, '42501', null, 'B cannot insert a segment owned by A');
select throws_ok($$
  insert into public.clipboard_items (id, owner_id, type, copied_at)
  values ('forged', '11111111-1111-1111-1111-111111111111', 'text', now())
$$, '42501', null, 'B cannot insert a clipboard item owned by A');
select throws_ok($$
  insert into public.revisions (owner_id, recording_id, at, field, source)
  values ('11111111-1111-1111-1111-111111111111', 'rec', now(), 'x', 'user')
$$, '42501', null, 'B cannot insert a revision owned by A');
select throws_ok($$
  insert into public.devices (id, owner_id, name, platform)
  values ('forged', '11111111-1111-1111-1111-111111111111', 'x', 'x')
$$, '42501', null, 'B cannot insert a device owned by A');
select throws_ok($$
  insert into public.sync_state (owner_id, device_id, table_name)
  values ('11111111-1111-1111-1111-111111111111', 'dev', 'x')
$$, '42501', null, 'B cannot insert sync state owned by A');

-- ---------------------------------------------------------------------------
-- B's updates of A's rows match nothing — RLS filters, it does not error.
-- ---------------------------------------------------------------------------

select is(pg_temp.affected($$
  update public.projects set name = 'stolen' where owner_id <> auth.uid()
$$), 0::bigint, 'B''s update of A''s project matches zero rows');
select is(pg_temp.affected($$
  update public.recordings set title = 'stolen' where owner_id <> auth.uid()
$$), 0::bigint, 'B''s update of A''s recording matches zero rows');
select is(pg_temp.affected($$
  update public.segments set text = 'stolen' where owner_id <> auth.uid()
$$), 0::bigint, 'B''s update of A''s segment matches zero rows');
select is(pg_temp.affected($$
  update public.clipboard_items set text = 'stolen' where owner_id <> auth.uid()
$$), 0::bigint, 'B''s update of A''s clipboard item matches zero rows');
select is(pg_temp.affected($$
  update public.devices set name = 'stolen' where owner_id <> auth.uid()
$$), 0::bigint, 'B''s update of A''s device matches zero rows');
select is(pg_temp.affected($$
  update public.sync_state set table_name = 'stolen' where owner_id <> auth.uid()
$$), 0::bigint, 'B''s update of A''s sync state matches zero rows');

-- ---------------------------------------------------------------------------
-- Foreign keys are owner-scoped: B cannot attach anything to a row only A
-- holds, and the error is the one B would get for an id that does not exist.
-- ---------------------------------------------------------------------------

select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');
insert into public.projects (id, name) values ('proj-only-a', 'Only A');
insert into public.recordings (id, file_path, duration_ms, type, status, created_at)
values ('rec-only-a', 'a.m4a', 1, 'audioRecording', 'saved', now());

select pg_temp.sign_in('22222222-2222-2222-2222-222222222222');

select throws_ok($$
  insert into public.segments
    (recording_id, index, file_path, type, created_at, duration_ms, size_bytes)
  values ('rec-only-a', 0, 'x.m4a', 'audioRecording', now(), 1, 1)
$$, '23503', null, 'B cannot attach a segment to A''s recording');
select throws_ok($$
  insert into public.revisions (recording_id, at, field, source)
  values ('rec-only-a', now(), 'title', 'user')
$$, '23503', null, 'B cannot attach a revision to A''s recording');
select throws_ok($$
  insert into public.recordings
    (id, file_path, duration_ms, type, status, created_at, project_id)
  values ('rec-2', 'x.m4a', 1, 'audioRecording', 'saved', now(), 'proj-only-a')
$$, '23503', null, 'B cannot bind a recording to A''s project');
select throws_ok($$
  insert into public.sync_state (device_id, table_name)
  values ('dev-only-a', 'recordings')
$$, '23503', null, 'B cannot attach sync state to a device it does not own');

-- ---------------------------------------------------------------------------
-- Even the owner cannot hand a row over, hard-delete it or edit history.
-- ---------------------------------------------------------------------------

select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');

select throws_ok($$
  update public.projects
     set owner_id = '22222222-2222-2222-2222-222222222222'
$$, '23514', 'owner_id is immutable', 'projects.owner_id is immutable');
select throws_ok($$
  update public.recordings
     set owner_id = '22222222-2222-2222-2222-222222222222'
$$, '23514', 'owner_id is immutable', 'recordings.owner_id is immutable');
select throws_ok($$
  update public.segments
     set owner_id = '22222222-2222-2222-2222-222222222222'
$$, '23514', 'owner_id is immutable', 'segments.owner_id is immutable');
select throws_ok($$
  update public.clipboard_items
     set owner_id = '22222222-2222-2222-2222-222222222222'
$$, '23514', 'owner_id is immutable', 'clipboard_items.owner_id is immutable');
select throws_ok($$
  update public.devices
     set owner_id = '22222222-2222-2222-2222-222222222222'
$$, '23514', 'owner_id is immutable', 'devices.owner_id is immutable');
select throws_ok($$
  update public.sync_state
     set owner_id = '22222222-2222-2222-2222-222222222222'
$$, '23514', 'owner_id is immutable', 'sync_state.owner_id is immutable');

select throws_ok($$ delete from public.projects $$, '42501', null,
  'projects: hard delete is not granted');
select throws_ok($$ delete from public.recordings $$, '42501', null,
  'recordings: hard delete is not granted');
select throws_ok($$ delete from public.segments $$, '42501', null,
  'segments: hard delete is not granted');
select throws_ok($$ delete from public.clipboard_items $$, '42501', null,
  'clipboard_items: hard delete is not granted');
select throws_ok($$ delete from public.revisions $$, '42501', null,
  'revisions: hard delete is not granted');
select throws_ok($$ delete from public.devices $$, '42501', null,
  'devices: hard delete is not granted');
select throws_ok($$ delete from public.sync_state $$, '42501', null,
  'sync_state: hard delete is not granted');

select throws_ok($$ update public.revisions set to_value = 'edited' $$,
  '42501', null, 'revisions are append-only');

-- ---------------------------------------------------------------------------
-- The server owns updated_at; the client owns version.
-- ---------------------------------------------------------------------------

select is(
  (select updated_at from public.recordings where id = 'rec'),
  now(),
  'the client-supplied updated_at on insert was overwritten');

select lives_ok($$
  update public.recordings
     set title = 'Renamed', deleted_at = now(), updated_at = '2000-01-01'
   where id = 'rec'
$$, 'the owner edits and tombstones a recording');

select is(
  (select updated_at from public.recordings where id = 'rec'),
  now(),
  'the client-supplied updated_at on update was overwritten');

select is(
  (select version from public.recordings where id = 'rec'),
  1::bigint,
  'the server does not bump version — the client owns it');

-- ---------------------------------------------------------------------------
-- anon gets a permission error on every table, never an empty result.
-- ---------------------------------------------------------------------------

select pg_temp.sign_out();
select set_config('role', 'anon', true);

select throws_ok($$ select count(*) from public.projects $$, '42501', null,
  'anon cannot read projects');
select throws_ok($$ select count(*) from public.recordings $$, '42501', null,
  'anon cannot read recordings');
select throws_ok($$ select count(*) from public.segments $$, '42501', null,
  'anon cannot read segments');
select throws_ok($$ select count(*) from public.clipboard_items $$, '42501', null,
  'anon cannot read clipboard items');
select throws_ok($$ select count(*) from public.revisions $$, '42501', null,
  'anon cannot read revisions');
select throws_ok($$ select count(*) from public.devices $$, '42501', null,
  'anon cannot read devices');
select throws_ok($$ select count(*) from public.sync_state $$, '42501', null,
  'anon cannot read sync state');

select pg_temp.sign_out();

select * from finish();

rollback;
