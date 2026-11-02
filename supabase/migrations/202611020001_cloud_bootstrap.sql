-- The integration credential may move the active SIC instance when a new
-- Lineboard desktop is paired. Existing cloud links follow that instance.
create function public.switch_sic_connection(p_hash text,p_instance uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare org uuid;
begin
 if p_instance is null then raise exception 'INVALID_INSTANCE'; end if;
 org:=public.integration_organization(p_hash);
 if org is null then raise exception 'FORBIDDEN'; end if;
 update public.sic_unit_links set instance_id=p_instance where organization_id=org;
 insert into public.sic_connections(organization_id,instance_id,allow_sandbox,enabled)
   values(org,p_instance,false,true)
 on conflict(organization_id) do update set instance_id=excluded.instance_id,enabled=true;
 return org;
end $$;

revoke all on function public.switch_sic_connection(text,uuid) from public,anon,authenticated;
grant execute on function public.switch_sic_connection(text,uuid) to service_role;
