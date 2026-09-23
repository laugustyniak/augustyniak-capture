-- pgTAP: the ownership guarantees of the capture media bucket (#198).
-- Run with `supabase test db`. Everything happens inside one transaction that
-- is rolled back, so the seeded users and objects never outlive the test.

begin;

select plan(9);

insert into auth.users (id, email)
values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@example.com');

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

select is(
  (select public from storage.buckets where id = 'captures'),
  false,
  'the captures bucket is private');

-- A writes under its own prefix.
select pg_temp.sign_in('11111111-1111-1111-1111-111111111111');
select lives_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('captures', '11111111-1111-1111-1111-111111111111/captures/r1/r1.m4a')$$,
  'an owner can upload under its own prefix');

select throws_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('captures', '22222222-2222-2222-2222-222222222222/captures/r1/r1.m4a')$$,
  '42501',
  null,
  'an upload under another user''s prefix is refused');

select throws_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('captures', 'captures/r1/r1.m4a')$$,
  '42501',
  null,
  'an upload with no owner prefix is refused');

select is(
  (select count(*) from storage.objects where bucket_id = 'captures'),
  1::bigint,
  'an owner sees its own object');

select is(
  pg_temp.affected(
    $$update storage.objects set name = name || '.x' where bucket_id = 'captures'$$),
  0::bigint,
  'an owner cannot rewrite an uploaded object');

-- Storage refuses a direct SQL delete with its own trigger whatever the
-- policies say, so the delete guarantee is asserted on the policies instead.
select is(
  (select count(*) from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and policyname like 'captures\_%' and cmd in ('UPDATE', 'DELETE', 'ALL')),
  0::bigint,
  'no policy lets an owner update or delete a capture object yet');

-- B sees none of it.
select pg_temp.sign_in('22222222-2222-2222-2222-222222222222');
select is(
  (select count(*) from storage.objects where bucket_id = 'captures'),
  0::bigint,
  'another user cannot see the object');

-- Anonymous sees none of it.
select pg_temp.sign_out();
select set_config('role', 'anon', true);
select is(
  (select count(*) from storage.objects where bucket_id = 'captures'),
  0::bigint,
  'an anonymous caller cannot see the object');

select * from finish();
rollback;
