-- Versioned garage snapshots. Authenticated clients cannot overwrite history or choose an owner.
create table public.garage_heads (
    owner_id uuid primary key references auth.users(id) on delete cascade,
    revision bigint not null default 0 check (revision >= 0)
);
create table public.garage_versions (
    owner_id uuid not null references auth.users(id) on delete cascade,
    revision bigint not null check (revision > 0),
    fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
    payload jsonb not null,
    created_at timestamptz not null default now(),
    device_name text not null,
    car_count integer not null,
    trip_count integer not null,
    primary key (owner_id, revision)
);
alter table public.garage_heads enable row level security;
alter table public.garage_versions enable row level security;
revoke all on public.garage_heads, public.garage_versions from anon, authenticated;
grant select on public.garage_heads, public.garage_versions to authenticated;
create policy own_head on public.garage_heads for select to authenticated using (owner_id = (select auth.uid()));
create policy own_versions on public.garage_versions for select to authenticated using (owner_id = (select auth.uid()));

create function public.garage_commit(p_expected bigint, p_fingerprint text, p_payload jsonb, p_device text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    uid uuid := auth.uid();
    current_revision bigint;
    result public.garage_versions;
begin
    if uid is null then raise exception 'Authentication required' using errcode = '42501'; end if;
    if p_expected is null or p_expected < 0 or p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$'
       or p_payload is null or pg_column_size(p_payload) > 20971520
       or (p_payload->>'version') is distinct from '2'
       or jsonb_typeof(p_payload->'tables'->'cars') is distinct from 'array'
       or jsonb_typeof(p_payload->'tables'->'trips') is distinct from 'array' then
        raise exception 'Invalid garage snapshot' using errcode = '22023';
    end if;
    if jsonb_array_length(p_payload->'tables'->'cars') = 0 then
        raise exception 'Missing car' using errcode = '22023';
    end if;
    -- Serializes even the first upload from two devices. All writes use this function.
    perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));
    insert into public.garage_heads(owner_id) values(uid) on conflict do nothing;
    select revision into current_revision from public.garage_heads where owner_id = uid for update;
    -- Retrying a committed request after a lost response must not create another version.
    select * into result from public.garage_versions where owner_id = uid and revision = current_revision;
    if result.fingerprint = p_fingerprint then
        return to_jsonb(result) - 'payload' - 'owner_id';
    end if;
    if current_revision <> p_expected then
        raise exception 'Garage changed on another device' using errcode = '40001';
    end if;
    insert into public.garage_versions(owner_id, revision, fingerprint, payload, device_name, car_count, trip_count)
    values(uid, current_revision + 1, p_fingerprint, p_payload, left(coalesce(p_device, 'iPhone'), 80),
           jsonb_array_length(p_payload->'tables'->'cars'), jsonb_array_length(p_payload->'tables'->'trips'))
    returning * into result;
    update public.garage_heads set revision = result.revision where owner_id = uid;
    -- Keep the latest 20 complete restore points, including the current one.
    delete from public.garage_versions where owner_id = uid and revision <= result.revision - 20;
    return to_jsonb(result) - 'payload' - 'owner_id';
end $$;
revoke all on function public.garage_commit(bigint, text, jsonb, text) from public, anon;
grant execute on function public.garage_commit(bigint, text, jsonb, text) to authenticated;

-- Account deletion is explicit in the app, and also removes all snapshots via FK cascade.
create function public.garage_delete_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
    if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
    delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.garage_delete_account() from public, anon;
grant execute on function public.garage_delete_account() to authenticated;
