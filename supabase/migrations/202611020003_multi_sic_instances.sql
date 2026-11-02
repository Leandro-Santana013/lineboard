-- Keep every registered desktop enabled. A second desktop must not steal the
-- organization's active link or prevent the first desktop from publishing.
alter table public.sic_connections drop constraint if exists sic_connections_organization_id_key;
drop index if exists public.sic_connections_one_enabled;

create or replace function public.switch_sic_connection(p_hash text,p_instance uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;
begin
 if p_instance is null then raise exception 'INVALID_INSTANCE'; end if;
 org:=public.integration_organization(p_hash);
 if org is null then raise exception 'FORBIDDEN'; end if;
 insert into public.sic_connections(organization_id,instance_id,allow_sandbox,enabled)
   values(org,p_instance,false,true)
 on conflict(organization_id,instance_id) do update set enabled=true;
 return org;
end $$;

revoke all on function public.switch_sic_connection(text,uuid) from public,anon,authenticated;
grant execute on function public.switch_sic_connection(text,uuid) to service_role;

-- The revision and quantity checks remain the conflict boundary. The source
-- instance is recorded for audit, but another enabled desktop may apply the
-- next revision after a normal snapshot pull.
do $$
declare definition text;
begin
 select pg_get_functiondef('public.apply_sic_event(text,jsonb)'::regprocedure) into definition;
 if position('SOURCE_CONFLICT' in definition)=0 then
   raise exception 'apply_sic_event SOURCE_CONFLICT guard not found';
 end if;
 definition:=replace(definition,
   'if link.instance_id<>source then raise exception ''SOURCE_CONFLICT''; end if;',
   'null;');
 execute definition;
end $$;

revoke all on function public.apply_sic_event(text,jsonb) from public,anon,authenticated;
grant execute on function public.apply_sic_event(text,jsonb) to service_role;
