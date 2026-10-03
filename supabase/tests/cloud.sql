\set ON_ERROR_STOP on
-- Standalone PostgreSQL fixture for CI; no production users or secrets involved.
create schema auth;
create role anon nologin;
create role authenticated nologin;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema public, auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
\ir ../migrations/202610030001_garage_cloud.sql
insert into auth.users values ('00000000-0000-0000-0000-000000000001'), ('00000000-0000-0000-0000-000000000002');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
do $$
declare p jsonb := '{"version":2,"tables":{"cars":[{"id":1}],"trips":[]}}'; r jsonb;
begin
    r := public.garage_commit(0, repeat('a',64), p, 'phone A');
    assert (r->>'revision')::int = 1, 'first commit';
    r := public.garage_commit(0, repeat('a',64), p, 'phone A');
    assert (r->>'revision')::int = 1, 'lost response retry is idempotent';
    begin
        perform public.garage_commit(0, repeat('b',64), p, 'phone B');
        raise exception 'stale write accepted';
    exception when sqlstate 'PT409' then null;
    end;
    begin
        delete from public.garage_versions;
        raise exception 'direct deletion accepted';
    exception when insufficient_privilege then null;
    end;
    for i in 2..23 loop
        perform public.garage_commit(i-1, lpad(to_hex(i),64,'0'), p, 'phone A');
    end loop;
    assert (select count(*) from public.garage_versions) = 20, 'bounded restore history';
    assert (select max(revision) from public.garage_versions) = 23, 'head preserved';
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
do $$
begin
    assert (select count(*) from public.garage_versions) = 0, 'other account data hidden';
    assert (select count(*) from public.garage_heads) = 0, 'other account head hidden';
    perform public.garage_commit(0, repeat('c',64), '{"version":2,"tables":{"cars":[{"id":2}],"trips":[]}}', 'phone B');
    assert (select count(*) from public.garage_versions) = 1, 'independent account';
    perform public.garage_delete_account();
    assert (select count(*) from public.garage_versions) = 0, 'account deletion cascades';
end $$;
reset role;
do $$ begin
    assert (select count(*) from public.garage_versions) = 20, 'other account survives deletion';
    assert not has_table_privilege('anon','public.garage_versions','SELECT'), 'anonymous reads denied';
    assert not has_function_privilege('anon','public.garage_commit(bigint,text,jsonb,text)','EXECUTE'), 'anonymous writes denied';
end $$;
select 'Cloud isolation and revision checks passed' as result;
