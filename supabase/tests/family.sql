\set ON_ERROR_STOP on
\ir ../migrations/202610260001_family_garage.sql
insert into auth.users values ('00000000-0000-0000-0000-000000000003'),('00000000-0000-0000-0000-000000000004');
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
do $$ declare g uuid; invite text; payload jsonb;
begin
 g := (public.family_action('create',null,'{"name":"Shared Fiesta"}')->>'id')::uuid;
 perform set_config('test.family_id',g::text,false);
 perform public.family_action('write',g,'{"section":"costs","revision":0,"records":[{"id":"cost1","title":"Oil","date":100,"amount":1000,"note":""}]}');
 invite := public.family_action('invite',g,'{"reads":["service","costs"],"writes":["service"]}')->>'token';
 perform set_config('test.family_invite',invite,false);
 begin
   perform public.family_action('write',g,'{"section":"costs","revision":0,"records":[]}');
   raise exception 'stale edit accepted';
 exception when sqlstate 'PT409' then null; end;
 begin
   perform public.family_action('invite',g,'{"reads":["service"],"writes":["trips"]}');
   raise exception 'invalid permissions accepted';
 exception when raise_exception then assert sqlerrm='invalid permissions'; end;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
do $$ declare g uuid := current_setting('test.family_id')::uuid; data jsonb;
begin
 assert public.family_action('list')='[]'::jsonb,'private garage not listed';
 begin perform public.family_action('read',g); raise exception 'uninvited read'; exception when insufficient_privilege then null; end;
 perform public.family_action('join',null,jsonb_build_object('token',current_setting('test.family_invite')));
 data := public.family_action('read',g);
 assert jsonb_array_length(data)=2,'only granted sections';
 assert not exists(select 1 from jsonb_array_elements(data) x where x->>'section'='trips'),'private trips hidden';
 perform public.family_action('write',g,'{"section":"service","revision":0,"records":[{"id":"s1","title":"Service","date":100,"note":""}]}');
 begin perform public.family_action('write',g,'{"section":"costs","revision":1,"records":[]}'); raise exception 'read only write'; exception when insufficient_privilege then null; end;
 begin perform public.family_action('invite',g,'{"reads":["trips"],"writes":[]}'); raise exception 'member invited outsider'; exception when insufficient_privilege then null; end;
 begin select records into data from public.family_sections; raise exception 'direct select'; exception when insufficient_privilege then null; end;
 assert (select count(*) from public.garage_versions)=0,'shared member cannot read private backup';
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
do $$ begin
 begin perform public.family_action('join',null,jsonb_build_object('token',current_setting('test.family_invite'))); raise exception 'token reused'; exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
do $$ declare g uuid := current_setting('test.family_id')::uuid; token text;
begin
 perform public.family_action('revoke',g,'{"member":"00000000-0000-0000-0000-000000000003"}');
 token := public.family_action('invite',g,'{"reads":["trips"],"writes":[]}')->>'token';
 perform set_config('test.cancelled_invite',token,false);
 perform public.family_action('cancel_invites',g);
 assert (select count(*) from public.garage_versions)=20,'private snapshots untouched';
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
do $$ begin
 begin perform public.family_action('read',current_setting('test.family_id')::uuid); raise exception 'revoked member read'; exception when insufficient_privilege then null; end;
 begin perform public.family_action('join',null,jsonb_build_object('token',current_setting('test.cancelled_invite'))); raise exception 'cancelled invite'; exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
 assert not has_function_privilege('anon','public.family_action(text,uuid,jsonb)','EXECUTE'),'anonymous cannot access family';
 assert not has_table_privilege('authenticated','public.family_sections','SELECT'),'no direct reads bypass permissions';
end $$;
select 'Family isolation and permissions checks passed' as result;
