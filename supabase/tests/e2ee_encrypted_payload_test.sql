begin;
select plan(8);

insert into auth.users (id, email) values
  ('33333333-3333-3333-3333-333333333333', 'e2ee_a@example.com'),
  ('44444444-4444-4444-4444-444444444444', 'e2ee_b@example.com');

create function pg_temp.sign_in(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true);
  select set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;

select pg_temp.sign_in('33333333-3333-3333-3333-333333333333');

-- 1. Insert E2EE settings for user A
insert into public.user_e2ee_settings (kdf_salt, kdf_algorithm, key_check_hash)
values ('salt123', 'pbkdf2_sha256', 'hash_verification_tag');

select is(
  (select count(*)::int from public.user_e2ee_settings where owner_id = '33333333-3333-3333-3333-333333333333'),
  1,
  'user A can insert and see their own E2EE settings'
);

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

-- 7. User B can insert their own E2EE settings
insert into public.user_e2ee_settings (kdf_salt, kdf_algorithm, key_check_hash)
values ('salt456', 'pbkdf2_sha256', 'hash_verification_tag_b');

select is(
  (select count(*)::int from public.user_e2ee_settings where owner_id = '44444444-4444-4444-4444-444444444444'),
  1,
  'user B can insert their own E2EE settings'
);

-- 8. Owner change trigger rejection
select throws_ok(
  $$ update public.user_e2ee_settings set owner_id = '33333333-3333-3333-3333-333333333333' where owner_id = '44444444-4444-4444-4444-444444444444' $$,
  'check_violation',
  'owner_id is immutable',
  'reject_owner_change trigger fires on user_e2ee_settings'
);

select * from finish();
rollback;
