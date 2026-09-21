begin;
select plan(24);

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@example.com');

create function pg_temp.sign_in(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true);
  select set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;

select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');

-- 1. insert at version 1
select is(
  (select public.sync_push('projects', '[{"id":"p1","name":"One","version":1}]'))->>'applied',
  '1', 'insert at version 1 applies');
select is((select name from public.projects where id = 'p1'), 'One',
  'the row landed');

-- 2. update at version 2 over server 1
select is(
  (select public.sync_push('projects', '[{"id":"p1","name":"Two","version":2}]'))->>'applied',
  '1', 'update at version 2 over server 1 applies');
select is((select name from public.projects where id = 'p1'), 'Two',
  'the update landed');

-- 3. stale push: version 2 again over server 2 → conflict with server row
select is(
  jsonb_array_length((select public.sync_push('projects',
    '[{"id":"p1","name":"Stale","version":2}]'))->'conflicts'),
  1, 'a stale version is returned as a conflict');
select is((select name from public.projects where id = 'p1'), 'Two',
  'a stale push changes nothing');
select is(
  ((select public.sync_push('projects',
    '[{"id":"p1","name":"Stale","version":2}]'))->'conflicts'->0)->>'version',
  '2', 'the conflict carries the server row');

-- 4. tombstone through the version gate
select is(
  (select public.sync_push('projects',
    '[{"id":"p1","name":"Two","version":3,"deleted_at":"2026-09-21T00:00:00Z"}]'))->>'applied',
  '1', 'tombstone applies at the next version');
select ok((select deleted_at is not null from public.projects where id = 'p1'),
  'deleted_at is set');

-- 5. revisions: natural key, no-op on repeat, never a conflict
insert into public.recordings (id, file_path, duration_ms, type, status, created_at)
values ('r1', 'r1.m4a', 1, 'audioRecording', 'saved', now());
select is(
  (select public.sync_push('revisions',
    '[{"recording_id":"r1","at":"2026-01-01T00:00:00Z","field":"title","from_value":"a","to_value":"b","source":"user"},
      {"recording_id":"r1","at":"2026-01-01T00:00:00Z","field":"title","from_value":"a","to_value":"b","source":"user"}]'))->>'applied',
  '1', 'a repeated revision is a no-op, not a conflict');

-- 6. B pushing A's id creates B's own row
select pg_temp.sign_in('22222222-2222-2222-2222-222222222222');
select is(
  (select public.sync_push('projects', '[{"id":"p1","name":"Mine","version":1}]'))->>'applied',
  '1', 'B inserts its own p1');
select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');
select is((select name from public.projects where id = 'p1'), 'Two',
  'A''s p1 is untouched by B''s push');

-- 7. unknown table raises
select throws_ok($$ select public.sync_push('auth_users', '[]') $$,
  '22023', null, 'an unknown table name is rejected');

-- 8. a mixed batch: a key-only push for an existing row lands in
--    `rejected`, not an error, and the sibling row still applies
create temporary table push_result (result jsonb);

insert into push_result
select public.sync_push('projects',
  '[{"id":"p1"},{"id":"p6","name":"Six","version":1}]');

select is((select result->>'applied' from push_result), '1',
  'the other row in a mixed batch still applies');
select is(
  jsonb_array_length((select result->'rejected' from push_result)), 1,
  'a key-only push for an existing row lands in rejected, not an error');
select is((select name from public.projects where id = 'p6'), 'Six',
  'the applied row in the mixed batch landed');

delete from push_result;

-- 9. an insert missing a required column is rejected with 23502; the
--    sibling row in the same batch still applies
insert into push_result
select public.sync_push('projects',
  '[{"id":"p7","version":1},{"id":"p8","name":"Eight","version":1}]');

select is((select result->>'applied' from push_result), '1',
  'the sibling row still applies when another row violates not-null');
select is(
  (select result->'rejected'->0->>'code' from push_result), '23502',
  'a missing not-null column is rejected with 23502');

delete from push_result;

-- 10. segments: the integer index key round-trips through the conflict
--     lookup
insert into push_result
select public.sync_push('segments',
  '[{"recording_id":"r1","index":0,"file_path":"seg.m4a","type":"audioRecording","created_at":"2026-01-01T00:00:00Z","duration_ms":100,"size_bytes":10,"version":1}]');

select is((select result->>'applied' from push_result), '1',
  'segment insert at version 1 applies');

delete from push_result;

insert into push_result
select public.sync_push('segments',
  '[{"recording_id":"r1","index":0,"file_path":"stale.m4a","type":"audioRecording","created_at":"2026-01-01T00:00:00Z","duration_ms":100,"size_bytes":10,"version":1}]');

select is(
  jsonb_array_length((select result->'conflicts' from push_result)), 1,
  'a stale segment push is a conflict');
select is(
  (select result->'conflicts'->0->'index' from push_result), '0'::jsonb,
  'the conflict row carries the integer index key as a number');
select is(
  (select result->'conflicts'->0->>'file_path' from push_result), 'seg.m4a',
  'the conflict carries the server row, not the pushed one');

delete from push_result;

-- 11. a value that fails to cast (data_exception, not integrity_constraint_
--     violation) is rejected with its SQLSTATE; the batch continues
insert into push_result
select public.sync_push('projects',
  '[{"id":"p9","name":"Bad","created_at":"not-a-date"},{"id":"p10","name":"Good","version":1}]');

select is((select result->>'applied' from push_result), '1',
  'the sibling row still applies when another row has an uncastable timestamp');
select is(
  (select result->'rejected'->0->>'code' from push_result), '22007',
  'a value that fails to cast is rejected with 22007, not swallowed as a syntax error');

drop table push_result;

select * from finish();
rollback;
