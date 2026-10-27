begin;
select plan(15);

insert into auth.users (id, email) values
  ('33333333-3333-3333-3333-333333333333', 'e2ee_a@example.com'),
  ('44444444-4444-4444-4444-444444444444', 'e2ee_b@example.com'),
  ('55555555-5555-5555-5555-555555555555', 'e2ee_c@example.com');

create function pg_temp.sign_in(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true);
  select set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;

select pg_temp.sign_in('33333333-3333-3333-3333-333333333333');

-- 1. Insert E2EE settings for user A, with the iteration count the key was
--    derived with (issue #298).
insert into public.user_e2ee_settings (kdf_salt, kdf_algorithm, key_check_hash, kdf_iterations)
values ('salt123', 'pbkdf2_sha256', 'kc1:hash_verification_tag', 600000);

select is(
  (select count(*)::int from public.user_e2ee_settings where owner_id = '33333333-3333-3333-3333-333333333333'),
  1,
  'user A can insert and see their own E2EE settings'
);

select is(
  (select kdf_iterations from public.user_e2ee_settings where owner_id = '33333333-3333-3333-3333-333333333333'),
  600000,
  'kdf_iterations is stored next to the salt'
);

-- The range check is exercised on insert: the row is insert-once, so there is
-- no update to try it on (issue #367). User C never gets a row.
select pg_temp.sign_in('55555555-5555-5555-5555-555555555555');

select throws_ok(
  $$ insert into public.user_e2ee_settings (kdf_salt, kdf_algorithm, key_check_hash, kdf_iterations)
     values ('salt789', 'pbkdf2_sha256', 'kc1:hash_c', 10) $$,
  '23514',
  null,
  'an iteration count below the floor is refused'
);

select throws_ok(
  $$ insert into public.user_e2ee_settings (kdf_salt, kdf_algorithm, key_check_hash, kdf_iterations)
     values ('salt789', 'pbkdf2_sha256', 'kc1:hash_c', 20000000) $$,
  '23514',
  null,
  'an iteration count above the ceiling is refused'
);

select pg_temp.sign_in('33333333-3333-3333-3333-333333333333');

-- 2. Verify encrypted_payload column on recordings
insert into public.recordings (id, file_path, duration_ms, type, status, created_at, encrypted_payload)
values ('rec-e2ee-1', 'rec-e2ee-1.m4a', 5000, 'audioRecording', 'saved', now(), 'enc:v1:testcipher');

select is(
  (select encrypted_payload from public.recordings where id = 'rec-e2ee-1'),
  'enc:v1:testcipher',
  'recording carries encrypted_payload'
);

-- 3. Verify sync_push accepts encrypted_payload
select is(
  (select public.sync_push('recordings',
    '[{"id":"rec-e2ee-2","file_path":"rec2.m4a","duration_ms":1000,"type":"audioRecording","status":"saved","created_at":"2026-10-06T00:00:00Z","version":1,"encrypted_payload":"enc:v1:syncpushcipher"}]'))->>'applied',
  '1',
  'sync_push applies recording with encrypted_payload'
);

select is(
  (select encrypted_payload from public.recordings where id = 'rec-e2ee-2'),
  'enc:v1:syncpushcipher',
  'pushed encrypted_payload landed on server'
);

-- 3b. A revision pushed under E2EE carries its envelope and no clear values
--     (issue #298: from_value/to_value were the last plaintext content).
select is(
  (select public.sync_push('revisions',
    '[{"recording_id":"rec-e2ee-2","at":"2026-10-06T10:00:00Z","field":"transcript","from_value":null,"to_value":null,"source":"user","encrypted_payload":"enc:v2:revisioncipher"}]'))->>'applied',
  '1',
  'sync_push applies a revision with encrypted_payload'
);

select is(
  (select encrypted_payload from public.revisions
    where recording_id = 'rec-e2ee-2' and field = 'transcript'),
  'enc:v2:revisioncipher',
  'pushed revision envelope landed on server with clear values null'
);

-- 4. Switch to user B
select pg_temp.sign_in('44444444-4444-4444-4444-444444444444');

-- 5. User B cannot see user A's E2EE settings
select is(
  (select count(*)::int from public.user_e2ee_settings where owner_id = '33333333-3333-3333-3333-333333333333'),
  0,
  'user B cannot select user A E2EE settings'
);

-- 6. User B cannot see user A's recordings or encrypted_payload
select is(
  (select count(*)::int from public.recordings where id in ('rec-e2ee-1', 'rec-e2ee-2')),
  0,
  'user B cannot select user A recordings'
);

-- 7. User B can insert their own E2EE settings; a row written without the
--    count (a pre-#298 client) describes its key with the old constant.
insert into public.user_e2ee_settings (kdf_salt, kdf_algorithm, key_check_hash)
values ('salt456', 'pbkdf2_sha256', 'hash_verification_tag_b');

select is(
  (select count(*)::int from public.user_e2ee_settings where owner_id = '44444444-4444-4444-4444-444444444444'),
  1,
  'user B can insert their own E2EE settings'
);

select is(
  (select kdf_iterations from public.user_e2ee_settings where owner_id = '44444444-4444-4444-4444-444444444444'),
  100000,
  'a row without kdf_iterations defaults to the pre-#298 constant'
);

-- 8. The row is insert-once (issue #367): an owner cannot update their own row
select throws_ok(
  $$ update public.user_e2ee_settings set kdf_salt = 'rotated' where owner_id = '44444444-4444-4444-4444-444444444444' $$,
  '42501',
  null,
  'an owner cannot update their own e2ee settings - the row is insert-once'
);

select is(
  (select count(*) from pg_policy p join pg_class c on c.oid = p.polrelid
    where c.relname = 'user_e2ee_settings' and p.polcmd = 'w'),
  0::bigint,
  'no update policy exists on user_e2ee_settings'
);

select * from finish();
rollback;
