-- Shared sections are deliberately separate from the private garage backup.
begin;
create table public.family_garages (
 id uuid primary key default gen_random_uuid(), owner uuid not null references auth.users(id) on delete cascade,
 name text not null check(length(name) between 1 and 150), created_at timestamptz not null default now()
);
create table public.family_members (
 garage uuid references public.family_garages(id) on delete cascade, member uuid references auth.users(id) on delete cascade,
 reads text[] not null, writes text[] not null, primary key(garage,member),
 check(reads <@ array['service','costs','trips']::text[] and writes <@ reads)
);
create table public.family_sections (
 garage uuid references public.family_garages(id) on delete cascade, section text not null check(section in ('service','costs','trips')),
 revision bigint not null default 0, records jsonb not null default '[]', primary key(garage,section),
 check(jsonb_typeof(records)='array' and octet_length(records::text)<=1000000)
);
create table public.family_invites (
 token_hash text primary key, garage uuid references public.family_garages(id) on delete cascade,
 reads text[] not null, writes text[] not null, expires timestamptz not null default now()+interval '7 days',
 check(reads <@ array['service','costs','trips']::text[] and writes <@ reads)
);
alter table public.family_garages enable row level security;
alter table public.family_members enable row level security;
alter table public.family_sections enable row level security;
alter table public.family_invites enable row level security;
revoke all on public.family_garages,public.family_members,public.family_sections,public.family_invites from anon,authenticated;

create function public.family_action(p_action text,p_garage uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
<<family>>
declare
 u uuid := auth.uid(); g public.family_garages; m public.family_members; inv public.family_invites;
 rid uuid; token text; section_name text; r text[]; w text[]; records jsonb; current_revision bigint; result jsonb;
begin
 if u is null then raise insufficient_privilege; end if;
 if p_action='list' then
   select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'name',a.name,'owned',a.owner=u,
     'reads',case when a.owner=u then array['service','costs','trips'] else b.reads end,
     'writes',case when a.owner=u then array['service','costs','trips'] else b.writes end) order by a.created_at),'[]')
   into result from public.family_garages a left join public.family_members b on b.garage=a.id and b.member=u where a.owner=u or b.member=u;
   return result;
 elsif p_action='create' then
   if (select count(*) from public.family_garages where owner=u)>=20 then raise exception 'garage limit'; end if;
   insert into public.family_garages(owner,name) values(u,btrim(p_data->>'name')) returning id into rid;
   insert into public.family_sections(garage,section) select rid,unnest(array['service','costs','trips']);
   return jsonb_build_object('id',rid);
 elsif p_action='join' then
   -- Lock the parent first, matching invitation/revocation lock order.
   select garage into rid from public.family_invites where token_hash=encode(sha256(convert_to(p_data->>'token','UTF8')),'hex');
   select * into g from public.family_garages where id=rid for update;
   select * into inv from public.family_invites where token_hash=encode(sha256(convert_to(p_data->>'token','UTF8')),'hex') for update;
   if inv.garage is null or inv.expires<=now() or g.owner=u then raise insufficient_privilege; end if;
   if exists(select 1 from public.family_members where garage=inv.garage and member=u) then raise exception 'already a member'; end if;
   insert into public.family_members values(inv.garage,u,inv.reads,inv.writes);
   delete from public.family_invites where token_hash=inv.token_hash;
   return jsonb_build_object('id',inv.garage);
 end if;
 select * into g from public.family_garages where id=p_garage for update;
 if g.id is null then raise insufficient_privilege; end if;
 select * into m from public.family_members where garage=g.id and member=u;
 if g.owner<>u and m.member is null then raise insufficient_privilege; end if;
 if p_action='read' then
   select coalesce(jsonb_agg(jsonb_build_object('section',s.section,'revision',s.revision,'records',s.records)),'[]') into result
   from public.family_sections s where s.garage=g.id and (g.owner=u or s.section=any(m.reads));
   return result;
 elsif p_action='write' then
   section_name := p_data->>'section'; records := p_data->'records';
   if g.owner<>u and not coalesce(section_name=any(m.writes),false) then raise insufficient_privilege; end if;
   select revision into current_revision from public.family_sections where garage=g.id and section=section_name;
   if current_revision is null then raise exception 'invalid section'; end if;
   if (p_data->>'revision')::bigint is distinct from current_revision then raise sqlstate 'PT409' using message='Reload this section before editing'; end if;
   if jsonb_typeof(records) is distinct from 'array' or jsonb_array_length(records)>2000 or octet_length(records::text)>1000000 then raise exception 'invalid records'; end if;
   if exists(select 1 from jsonb_array_elements(records) e where jsonb_typeof(e)<>'object' or length(e->>'title') not between 1 and 200
      or e->>'id' is null or e->>'title' is null or jsonb_typeof(e->'date') is distinct from 'number'
      or exists(select 1 from jsonb_object_keys(e) k where k not in ('id','title','date','amount','km','note'))) then raise exception 'invalid record'; end if;
   if (select count(*) from jsonb_array_elements(records)) <> (select count(distinct e->>'id') from jsonb_array_elements(records) e) then raise exception 'duplicate id'; end if;
   update public.family_sections set records=family.records,revision=revision+1 where garage=g.id and section=section_name;
   return jsonb_build_object('revision',current_revision+1);
 elsif p_action='leave' then
   if g.owner=u then raise exception 'owner cannot leave'; end if;
   delete from public.family_members where garage=g.id and member=u; return '{}';
 end if;
 if g.owner<>u then raise insufficient_privilege; end if;
 if p_action in ('invite','permissions') then
   select coalesce(array_agg(value),'{}') into r from jsonb_array_elements_text(p_data->'reads');
   select coalesce(array_agg(value),'{}') into w from jsonb_array_elements_text(p_data->'writes');
   if cardinality(r)=0 or not r <@ array['service','costs','trips']::text[] or not w <@ r then raise exception 'invalid permissions'; end if;
   if p_action='invite' then
     if (select count(*) from public.family_invites where garage=g.id and expires>now())>=20 then raise exception 'invite limit'; end if;
     token := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
     insert into public.family_invites(token_hash,garage,reads,writes) values(encode(sha256(convert_to(token,'UTF8')),'hex'),g.id,r,w);
     return jsonb_build_object('token',token);
   end if;
   update public.family_members set reads=r,writes=w where garage=g.id and member=(p_data->>'member')::uuid;
 elsif p_action='members' then
   select coalesce(jsonb_agg(jsonb_build_object('id',member,'reads',reads,'writes',writes)),'[]') into result from public.family_members where garage=g.id;
   return result;
 elsif p_action='revoke' then
   delete from public.family_members where garage=g.id and member=(p_data->>'member')::uuid;
 elsif p_action='cancel_invites' then
   delete from public.family_invites where garage=g.id;
 elsif p_action='delete' then
   delete from public.family_garages where id=g.id;
 else raise exception 'invalid action'; end if;
 return '{}';
end $$;
revoke all on function public.family_action(text,uuid,jsonb) from public,anon;
grant execute on function public.family_action(text,uuid,jsonb) to authenticated;
commit;
