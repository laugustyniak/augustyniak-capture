-- Version-gated push for the user-owned metadata tables (#194).
--
-- `security invoker`: every policy from the schema migration still applies,
-- so this function can only ever touch the caller's rows. `owner_id` is never
-- read from the payload — the column default fills it on insert and the
-- ownership trigger refuses a change on update. `updated_at` is likewise
-- ignored; the server stamps it.
--
-- For the six versioned tables a row is applied when it updates a row whose
-- version is exactly one behind, or when it inserts (tried only once no
-- update matched). The update path only ever sets the columns the payload
-- actually carries, so a tombstone — id, version and deleted_at, nothing
-- else — can update an existing row without needing every not-null column
-- resent; the insert path still requires them all, same as ever, since a
-- brand-new row has no prior server state to fall back on. A row that
-- matches nothing existing is returned in `conflicts` with the server's
-- current row, so the caller can resolve without a second round trip.
-- `revisions` has no version and no update grant: it inserts on its natural
-- key and a repeat is a no-op.
--
-- Each row runs in its own subtransaction (a nested `begin … exception …
-- end`), so one bad row never aborts the batch. A row whose data is
-- malformed for its table — any data exception (class 22: a value that will
-- not cast, an out-of-range number, a bad timestamp, …), any integrity
-- constraint violation (class 23: a missing not-null column, a bad foreign
-- key, a failed check), an unknown column in the payload, or (checked up
-- front, before it can reach the SQL parser as a malformed statement) a row
-- with no columns beyond its key — is appended to `rejected` with its
-- SQLSTATE instead. A permissions failure (RLS, `insufficient_privilege`)
-- and the `invalid_parameter_value` this function itself raises are outside
-- those classes, so they propagate and fail the call loudly.

create or replace function public.sync_push(table_name text, rows jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  key_columns text[];
  data_columns text[];
  row jsonb;
  applied integer := 0;
  conflicts jsonb := '[]'::jsonb;
  rejected jsonb := '[]'::jsonb;
  touched integer;
  current_row jsonb;
begin
  key_columns := case table_name
    when 'projects' then array['id']
    when 'recordings' then array['id']
    when 'segments' then array['recording_id', 'index']
    when 'clipboard_items' then array['id']
    when 'revisions' then array['recording_id', 'at', 'field']
    when 'devices' then array['id']
    when 'sync_state' then array['device_id', 'table_name']
    else null
  end;
  if key_columns is null then
    raise exception 'unknown table %', table_name
      using errcode = 'invalid_parameter_value';
  end if;

  if jsonb_typeof(rows) <> 'array' then
    raise exception 'rows must be a json array'
      using errcode = 'invalid_parameter_value';
  end if;

  for row in select value from jsonb_array_elements(rows)
  loop
    begin
      row := row - 'owner_id' - 'updated_at';
      select array_agg(k order by k) into data_columns
        from jsonb_object_keys(row) k;

      if table_name = 'revisions' then
        -- A row that strips to no columns at all would render an empty
        -- column list and fail to parse; caught here as a rejection rather
        -- than a syntax error that would abort the whole call.
        if data_columns is null then
          raise exception 'row for % has no columns', table_name
            using errcode = 'not_null_violation';
        end if;
        execute format(
          'insert into public.revisions (%s) select %s from jsonb_populate_record(null::public.revisions, $1) on conflict do nothing',
          (select string_agg(quote_ident(c), ', ') from unnest(data_columns) c),
          (select string_agg(quote_ident(c), ', ') from unnest(data_columns) c))
        using row;
        get diagnostics touched = row_count;
        applied := applied + touched;
        continue;
      end if;

      -- A row with no columns beyond its key would render `set` empty and
      -- fail to parse; caught here as a rejection rather than a syntax error
      -- that would abort the whole call.
      if not exists (
        select 1 from unnest(data_columns) c where c <> all (key_columns)
      ) then
        raise exception 'row for % has no columns beyond its key', table_name
          using errcode = 'not_null_violation';
      end if;

      -- Update first, touching only the columns the payload actually
      -- carries. `jsonb_populate_record` fills every column this table has
      -- — NULL for one the payload omits — into a plain, unwritten `src`
      -- record, so referencing `src.<col>` here never trips a NOT NULL
      -- check the way giving those same omitted columns to a bare INSERT
      -- would; a tombstone (id + version + deleted_at only) is exactly
      -- such a payload, and its target row already has every other
      -- NOT NULL column filled in from when it was first inserted. RLS's
      -- own `..._update_own` policy already confines this to the caller's
      -- rows, the same way it always has for the old `on conflict do
      -- update` path this replaces.
      execute format(
        'update public.%1$I t set %2$s '
        'from jsonb_populate_record(null::public.%1$I, $1) as src '
        'where %3$s and t.version = coalesce(src.version, 0) - 1',
        table_name,
        (select string_agg(format('%1$I = src.%1$I', c), ', ')
           from unnest(data_columns) c where c <> all (key_columns)),
        (select string_agg(format('t.%1$I = src.%1$I', c), ' and ')
           from unnest(key_columns) c))
      using row;
      get diagnostics touched = row_count;

      if touched = 1 then
        applied := applied + 1;
        continue;
      end if;

      -- Not updated: either this row does not exist yet for this owner, or
      -- it does and lost the version race — the same lookup answers both,
      -- and is also the conflict row a stale push reports.
      execute format(
        'select to_jsonb(t) from public.%1$I t where %2$s',
        table_name,
        (select string_agg(format('t.%1$I = ($1->>%2$L)::%3$s', c, c,
           format_type(a.atttypid, a.atttypmod)), ' and ')
           from unnest(key_columns) c
           join pg_attribute a on a.attname = c
            and a.attrelid = format('public.%I', table_name)::regclass))
      into current_row using row;

      if current_row is not null then
        conflicts := conflicts || current_row;
        continue;
      end if;

      -- Genuinely new to this owner: a full insert, which still enforces
      -- every not-null column exactly as before — a brand-new row has no
      -- prior server-side state to fall back on for the columns it omits.
      execute format(
        'insert into public.%1$I (%2$s) select %2$s from jsonb_populate_record(null::public.%1$I, $1)',
        table_name,
        (select string_agg(quote_ident(c), ', ') from unnest(data_columns) c))
      using row;
      applied := applied + 1;
    exception
      when data_exception or integrity_constraint_violation
        or undefined_column then
        rejected := rejected
          || jsonb_build_object('row', row, 'code', sqlstate);
    end;
  end loop;

  return jsonb_build_object(
    'applied', applied, 'conflicts', conflicts, 'rejected', rejected);
end;
$$;

revoke all on function public.sync_push(text, jsonb) from public, anon;
grant execute on function public.sync_push(text, jsonb) to authenticated;

-- A tiny clock RPC. `pull` needs the server's `now()` to compute its lag
-- window; PostgREST has no clock endpoint of its own.
create or replace function public.sync_now() returns timestamptz
language sql stable security invoker set search_path = '' as $$ select now() $$;
revoke all on function public.sync_now() from public, anon;
grant execute on function public.sync_now() to authenticated;
