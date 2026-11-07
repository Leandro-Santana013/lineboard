-- Allow an existing desktop instance to renew its integration credential.
-- This covers reinstallations or a lost local config without allowing a code
-- from one organization to take over an instance belonging to another one.
create or replace function public.consume_desktop_activation(
 p_code_hash text,
 p_instance uuid,
 p_device_name text,
 p_token_hash text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare activation public.desktop_activation_codes; existing public.desktop_installations; key_id uuid; installation_id uuid;
begin
 if p_code_hash is null or p_code_hash !~ '^[a-f0-9]{64}$' then raise exception 'ACTIVATION_INVALID'; end if;
 if p_instance is null or p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then raise exception 'ACTIVATION_INVALID'; end if;
 if p_device_name is null or length(trim(p_device_name)) not between 1 and 120 then raise exception 'ACTIVATION_INVALID'; end if;
 select * into activation from public.desktop_activation_codes where code_hash=p_code_hash for update;
 if not found then raise exception 'ACTIVATION_INVALID'; end if;
 if activation.revoked_at is not null then raise exception 'ACTIVATION_REVOKED'; end if;
 if activation.expires_at <= now() then raise exception 'ACTIVATION_EXPIRED'; end if;
 if activation.used_count >= activation.max_uses then raise exception 'ACTIVATION_LIMIT_REACHED'; end if;

 select * into existing from public.desktop_installations where instance_id=p_instance for update;
 if found then
   if existing.organization_id <> activation.organization_id then raise exception 'ACTIVATION_INSTANCE_USED'; end if;
   update public.integration_keys
      set token_hash=p_token_hash,
          name='Lineboard desktop: '||trim(p_device_name),
          revoked_at=null
    where id=existing.integration_key_id
    returning id into key_id;
   if key_id is null then raise exception 'ACTIVATION_INVALID'; end if;
   update public.desktop_installations
      set activation_code_id=activation.id,
          device_name=trim(p_device_name),
          activated_at=now(),
          last_seen_at=null
    where id=existing.id
    returning id into installation_id;
   update public.desktop_activation_codes set used_count=used_count+1 where id=activation.id;
   return jsonb_build_object('organization_id',activation.organization_id,'installation_id',installation_id,'integration_key_id',key_id);
 end if;

 insert into public.integration_keys(organization_id,name,token_hash)
   values(activation.organization_id,'Lineboard desktop: '||trim(p_device_name),p_token_hash)
   returning id into key_id;
 insert into public.desktop_installations(organization_id,instance_id,activation_code_id,integration_key_id,device_name)
   values(activation.organization_id,p_instance,activation.id,key_id,trim(p_device_name))
   returning id into installation_id;
 update public.desktop_activation_codes set used_count=used_count+1 where id=activation.id;
 return jsonb_build_object('organization_id',activation.organization_id,'installation_id',installation_id,'integration_key_id',key_id);
end $$;
