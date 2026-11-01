-- Commands from the authenticated mobile app to the local SIC adapter.
-- The desktop subscribes to this table through Supabase Realtime and writes the
-- result back through the service-only acknowledgement function.
create table if not exists public.sic_commands (
  organization_id uuid not null references public.organizations(id),
  command_id uuid not null,
  request_id uuid not null,
  instance_id uuid not null,
  kind text not null check (kind in ('product.create','cart.add','cart.remove','stock.adjust','cart.confirm')),
  payload jsonb not null,
  status text not null default 'pending' check (status in ('pending','processing','completed','failed','conflict')),
  result jsonb,
  error_code text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, command_id),
  unique (organization_id, request_id)
);

alter table public.sic_commands enable row level security;
revoke all on public.sic_commands from anon, authenticated;
grant select on public.sic_commands to authenticated;
create policy sic_command_read on public.sic_commands
  for select to authenticated
  using (created_by = (select auth.uid()) or private.is_member(organization_id, true));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sic_commands'
  ) then
    execute 'alter publication supabase_realtime add table public.sic_commands';
  end if;
end $$;

create or replace function public.queue_sic_command(
  p_org uuid,
  p_request_id uuid,
  p_instance_id uuid,
  p_kind text,
  p_payload jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  existing public.sic_commands;
  command uuid;
begin
  if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
  if p_request_id is null or p_instance_id is null or p_kind not in ('product.create','cart.add','cart.remove','stock.adjust','cart.confirm') or p_payload is null then
    raise exception 'INVALID_COMMAND';
  end if;
  if not exists (
    select 1 from public.sic_connections
    where organization_id = p_org and instance_id = p_instance_id and enabled
  ) then raise exception 'SIC_CONNECTION_NOT_REGISTERED'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_org::text || ':command:' || p_request_id::text, 0));
  select * into existing from public.sic_commands
    where organization_id = p_org and request_id = p_request_id for update;
  if found then
    if existing.instance_id <> p_instance_id or existing.kind <> p_kind or existing.payload <> p_payload then
      raise exception 'IDEMPOTENCY_CONFLICT';
    end if;
    return jsonb_build_object('command_id', existing.command_id, 'status', existing.status,
      'result', existing.result, 'error_code', existing.error_code, 'replayed', true);
  end if;

  command := gen_random_uuid();
  insert into public.sic_commands(organization_id,command_id,request_id,instance_id,kind,payload,created_by)
    values(p_org,command,p_request_id,p_instance_id,p_kind,p_payload,auth.uid());
  return jsonb_build_object('command_id', command, 'status', 'pending', 'replayed', false);
end $$;

create or replace function public.ack_sic_command(
  p_org uuid,
  p_command_id uuid,
  p_instance_id uuid,
  p_status text,
  p_result jsonb default null,
  p_error_code text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare row public.sic_commands;
begin
  if p_status not in ('processing','completed','failed','conflict') then raise exception 'INVALID_COMMAND_STATUS'; end if;
  select * into row from public.sic_commands
    where organization_id = p_org and command_id = p_command_id and instance_id = p_instance_id for update;
  if not found then raise exception 'COMMAND_NOT_FOUND'; end if;
  if row.status in ('completed','failed','conflict') then
    return jsonb_build_object('command_id', row.command_id, 'status', row.status, 'result', row.result, 'error_code', row.error_code, 'replayed', true);
  end if;
  update public.sic_commands set status=p_status,result=p_result,error_code=p_error_code,updated_at=now()
    where organization_id=p_org and command_id=p_command_id;
  return jsonb_build_object('command_id', row.command_id, 'status', p_status, 'result', p_result, 'error_code', p_error_code, 'replayed', false);
end $$;

revoke all on function public.queue_sic_command(uuid,uuid,uuid,text,jsonb),
  public.ack_sic_command(uuid,uuid,uuid,text,jsonb,text) from public, anon;
grant execute on function public.queue_sic_command(uuid,uuid,uuid,text,jsonb) to authenticated;
revoke all on function public.ack_sic_command(uuid,uuid,uuid,text,jsonb,text) from authenticated;
grant execute on function public.ack_sic_command(uuid,uuid,uuid,text,jsonb,text) to service_role;
