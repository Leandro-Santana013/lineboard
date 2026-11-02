-- Allow one active desktop per organization while keeping old instances
-- addressable until their cloud links are moved to the new instance.
alter table public.sic_connections drop constraint if exists sic_connections_organization_id_key;
create unique index if not exists sic_connections_one_enabled on public.sic_connections(organization_id) where enabled;

create or replace function public.switch_sic_connection(p_hash text,p_instance uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;
begin
 if p_instance is null then raise exception 'INVALID_INSTANCE'; end if;
 org:=public.integration_organization(p_hash);
 if org is null then raise exception 'FORBIDDEN'; end if;
 insert into public.sic_connections(organization_id,instance_id,allow_sandbox,enabled)
   values(org,p_instance,false,false)
 on conflict(organization_id,instance_id) do update set enabled=false;
 update public.sic_connections set enabled=false where organization_id=org and instance_id<>p_instance;
 update public.sic_unit_links set instance_id=p_instance where organization_id=org;
 update public.sic_connections set enabled=true where organization_id=org and instance_id=p_instance;
 return org;
end $$;

revoke all on function public.switch_sic_connection(text,uuid) from public,anon,authenticated;
grant execute on function public.switch_sic_connection(text,uuid) to service_role;
