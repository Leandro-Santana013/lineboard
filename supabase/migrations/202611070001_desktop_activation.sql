-- One-time/bootstrap credentials for public desktop installers. The raw code
-- is never stored; the activation Edge Function receives it once and stores
-- only its SHA-256 hash through the RPC below.
create table public.desktop_activation_codes (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 name text not null check (length(trim(name)) between 1 and 120),
 code_hash text not null unique check (code_hash ~ '^[a-f0-9]{64}$'),
 max_uses integer not null default 1 check (max_uses between 1 and 20),
 used_count integer not null default 0 check (used_count >= 0 and used_count <= max_uses),
 expires_at timestamptz not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 revoked_at timestamptz
);

create table public.desktop_installations (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 instance_id uuid not null unique,
 activation_code_id uuid not null references public.desktop_activation_codes(id),
 integration_key_id uuid not null unique references public.integration_keys(id),
 device_name text not null check (length(trim(device_name)) between 1 and 120),
 activated_at timestamptz not null default now(),
 last_seen_at timestamptz
);

alter table public.desktop_activation_codes enable row level security;
alter table public.desktop_installations enable row level security;
revoke all on public.desktop_activation_codes, public.desktop_installations from public, anon, authenticated;

create function public.create_desktop_activation(
 p_org uuid,
 p_name text,
 p_code_hash text,
 p_max_uses integer default 1,
 p_expires_at timestamptz default now() + interval '24 hours'
)
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not private.is_member(p_org,true) then raise exception 'FORBIDDEN'; end if;
 if p_name is null or length(trim(p_name)) not between 1 and 120 then raise exception 'INVALID_ACTIVATION_NAME'; end if;
 if p_code_hash is null or p_code_hash !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_ACTIVATION_HASH'; end if;
 if p_max_uses is null or p_max_uses not between 1 and 20 then raise exception 'INVALID_ACTIVATION_LIMIT'; end if;
 if p_expires_at is null or p_expires_at <= now() or p_expires_at > now() + interval '30 days' then raise exception 'INVALID_ACTIVATION_EXPIRY'; end if;
 insert into public.desktop_activation_codes(organization_id,name,code_hash,max_uses,expires_at,created_by)
   values(p_org,trim(p_name),p_code_hash,p_max_uses,p_expires_at,auth.uid())
   returning id into result;
 return result;
end $$;

create function public.consume_desktop_activation(
 p_code_hash text,
 p_instance uuid,
 p_device_name text,
 p_token_hash text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare activation public.desktop_activation_codes; key_id uuid; installation_id uuid;
begin
 if p_code_hash is null or p_code_hash !~ '^[a-f0-9]{64}$' then raise exception 'ACTIVATION_INVALID'; end if;
 if p_instance is null or p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then raise exception 'ACTIVATION_INVALID'; end if;
 if p_device_name is null or length(trim(p_device_name)) not between 1 and 120 then raise exception 'ACTIVATION_INVALID'; end if;
 select * into activation from public.desktop_activation_codes where code_hash=p_code_hash for update;
 if not found then raise exception 'ACTIVATION_INVALID'; end if;
 if activation.revoked_at is not null then raise exception 'ACTIVATION_REVOKED'; end if;
 if activation.expires_at <= now() then raise exception 'ACTIVATION_EXPIRED'; end if;
 if activation.used_count >= activation.max_uses then raise exception 'ACTIVATION_LIMIT_REACHED'; end if;
 if exists(select 1 from public.desktop_installations where instance_id=p_instance) then raise exception 'ACTIVATION_INSTANCE_USED'; end if;
 insert into public.integration_keys(organization_id,name,token_hash)
   values(activation.organization_id,'Lineboard desktop: '||trim(p_device_name),p_token_hash)
   returning id into key_id;
 insert into public.desktop_installations(organization_id,instance_id,activation_code_id,integration_key_id,device_name)
   values(activation.organization_id,p_instance,activation.id,key_id,trim(p_device_name))
   returning id into installation_id;
 update public.desktop_activation_codes set used_count=used_count+1 where id=activation.id;
 return jsonb_build_object('organization_id',activation.organization_id,'installation_id',installation_id,'integration_key_id',key_id);
end $$;

revoke all on function public.create_desktop_activation(uuid,text,text,integer,timestamptz) from public, anon;
grant execute on function public.create_desktop_activation(uuid,text,text,integer,timestamptz) to authenticated;
revoke all on function public.consume_desktop_activation(text,uuid,text,text) from public, anon, authenticated;
grant execute on function public.consume_desktop_activation(text,uuid,text,text) to service_role;
