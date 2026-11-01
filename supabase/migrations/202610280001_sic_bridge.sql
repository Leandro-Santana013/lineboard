-- SIC remains local. Cloud stock is changed by operations, never blind snapshot replacement.
create table public.sic_connections (
 organization_id uuid not null references public.organizations(id),
 instance_id uuid not null,
 allow_sandbox boolean not null default false,
 enabled boolean not null default true,
 primary key(organization_id, instance_id),
 unique(organization_id)
);
create table public.sic_unit_links (
 organization_id uuid not null,
 stock_item_id uuid not null,
 instance_id uuid not null,
 last_revision bigint not null,
 last_quantity integer not null check(last_quantity in (0,1)),
 snapshot jsonb not null,
 foreign key(organization_id,stock_item_id) references public.stock_items(organization_id,id),
 foreign key(organization_id,instance_id) references public.sic_connections(organization_id,instance_id),
 primary key(organization_id,stock_item_id)
);
create table public.sic_sync_events (
 organization_id uuid not null references public.organizations(id),
 event_id uuid not null,
 instance_id uuid not null,
 request jsonb not null,
 result jsonb not null,
 created_at timestamptz not null default now(),
 primary key(organization_id,event_id)
);
do $$
declare table_name text;
begin
 foreach table_name in array array['sic_connections','sic_unit_links','sic_sync_events'] loop
  execute format('alter table public.%I enable row level security',table_name);
  execute format('revoke all on public.%I from anon,authenticated',table_name);
  execute format('grant select on public.%I to authenticated',table_name);
  execute format('create policy tenant_read on public.%I for select to authenticated using (private.is_member(organization_id))',table_name);
 end loop;
end $$;

alter table public.stock_movements drop constraint stock_movements_reason_check;
alter table public.stock_movements add constraint stock_movements_reason_check check(reason in ('initial','sale','adjustment'));

create function public.register_sic_connection(p_org uuid,p_instance uuid,p_allow_sandbox boolean default false)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.is_member(p_org,true) then raise exception 'FORBIDDEN'; end if;
 insert into public.sic_connections(organization_id,instance_id,allow_sandbox) values(p_org,p_instance,p_allow_sandbox)
 on conflict(organization_id,instance_id) do update set allow_sandbox=excluded.allow_sandbox,enabled=true;
end $$;

create function public.apply_sic_event(p_hash text,p_event jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 org uuid; source uuid; event uuid; connection public.sic_connections;
 previous public.sic_sync_events; link public.sic_unit_links; stock public.stock_items;
 kind text; payload jsonb; unit jsonb; result jsonb; lines jsonb;
 unit_id uuid; product_id uuid; unit_variant uuid; revision bigint; qty integer;
 actor uuid; delta integer; receipt jsonb;
begin
 org:=public.integration_organization(p_hash);
 if org is null then raise exception 'FORBIDDEN'; end if;
 source:=(p_event->>'instance_id')::uuid;
 event:=(p_event->>'event_id')::uuid;
 kind:=p_event->>'kind'; payload:=p_event->'payload';
 if source is null or event is null or kind not in ('unit.upsert','sale.confirmed','stock.adjusted') or payload is null then raise exception 'INVALID_EVENT'; end if;
 perform pg_advisory_xact_lock(hashtextextended(org::text||':sic-sync',0));
 select * into connection from public.sic_connections where organization_id=org and instance_id=source and enabled for update;
 if not found then raise exception 'SIC_CONNECTION_NOT_REGISTERED'; end if;
 if p_event->>'mode' is distinct from 'sandbox' and p_event->>'mode' is distinct from 'production' then raise exception 'INVALID_EVENT_MODE'; end if;
 if p_event->>'mode'='sandbox' and not connection.allow_sandbox then raise exception 'SANDBOX_NOT_ALLOWED'; end if;
 select * into previous from public.sic_sync_events where organization_id=org and event_id=event;
 if found then
  if previous.request<>p_event then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return previous.result||jsonb_build_object('replayed',true);
 end if;
 select user_id into actor from public.memberships where organization_id=org and role='admin' order by user_id limit 1;
 if actor is null then raise exception 'ADMIN_REQUIRED'; end if;
 result:=jsonb_build_object('event_id',event,'state','applied','replayed',false);
 if kind in ('unit.upsert','stock.adjusted') then
  unit:=case when kind='stock.adjusted' then payload->'unit' else payload end;
  unit_id:=(unit->>'stock_item_id')::uuid; product_id:=(unit->>'product_id')::uuid; unit_variant:=(unit->>'variant_id')::uuid;
  revision:=(unit->>'revision')::bigint; qty:=(unit->>'quantity')::integer;
  if unit_id is null or product_id is null or unit_variant is null or revision is null or revision<1 or qty is null or qty not in (0,1)
     or unit->>'barcode' is null or unit->>'barcode' !~ '^SLB-[0-9]{12}$' or unit->>'name' is null or length(trim(unit->>'name')) not between 1 and 160 then raise exception 'INVALID_UNIT'; end if;
  select * into link from public.sic_unit_links where organization_id=org and stock_item_id=unit_id for update;
  if found then
   if link.instance_id<>source then raise exception 'SOURCE_CONFLICT'; end if;
   select * into stock from public.stock_items where organization_id=org and id=unit_id for update;
   if revision<=link.last_revision then
    if revision=link.last_revision and unit<>link.snapshot then result:=result||jsonb_build_object('state','conflict','reason','REVISION_CONFLICT');
    else result:=result||jsonb_build_object('state','ignored','reason','OLD_REVISION'); end if;
   elsif stock.quantity<>link.last_quantity then result:=result||jsonb_build_object('state','conflict','reason','CLOUD_STOCK_CONFLICT');
   elsif stock.barcode<>unit->>'barcode' then result:=result||jsonb_build_object('state','conflict','reason','BARCODE_CONFLICT');
   else
    insert into public.variants(id,organization_id,product_id,color,size) values(unit_variant,org,product_id,coalesce(unit->>'color',''),coalesce(unit->>'size','')) on conflict(id) do nothing;
    delta:=qty-stock.quantity;
    update public.stock_items set variant_id=unit_variant,quantity=qty,updated_at=now() where organization_id=org and id=unit_id;
    if delta<>0 then insert into public.stock_movements(organization_id,stock_item_id,delta,reason) values(org,unit_id,delta,'adjustment'); end if;
    update public.sic_unit_links set last_revision=revision,last_quantity=qty,snapshot=unit where organization_id=org and stock_item_id=unit_id;
   end if;
  else
   if kind='stock.adjusted' then raise exception 'UNIT_NOT_IMPORTED'; end if;
   if exists(select 1 from public.stock_items where barcode=unit->>'barcode' or id=unit_id) then
    result:=result||jsonb_build_object('state','conflict','reason','BARCODE_CONFLICT');
   else
    insert into public.products(id,organization_id,name,brand,tracking,notes,created_by) values(product_id,org,unit->>'name',coalesce(unit->>'brand',''),'individual',coalesce(unit->>'notes',''),actor) on conflict(id) do nothing;
    insert into public.variants(id,organization_id,product_id,color,size) values(unit_variant,org,product_id,coalesce(unit->>'color',''),coalesce(unit->>'size','')) on conflict(id) do nothing;
    insert into public.stock_items(id,organization_id,variant_id,barcode,tracking,quantity) values(unit_id,org,unit_variant,unit->>'barcode','individual',qty);
    if qty<>0 then insert into public.stock_movements(organization_id,stock_item_id,delta,reason) values(org,unit_id,qty,'initial'); end if;
    insert into public.sic_unit_links(organization_id,stock_item_id,instance_id,last_revision,last_quantity,snapshot) values(org,unit_id,source,revision,qty,unit);
   end if;
  end if;
 elsif kind='sale.confirmed' then
  if jsonb_typeof(payload->'items') is distinct from 'array' or jsonb_array_length(payload->'items')<1 then raise exception 'INVALID_SALE'; end if;
  for unit in select value from jsonb_array_elements(payload->'items') order by value->>'barcode' loop
   unit_id:=(unit->>'stock_item_id')::uuid;
   select * into link from public.sic_unit_links where organization_id=org and stock_item_id=unit_id and instance_id=source for update;
   if not found then raise exception 'UNIT_NOT_IMPORTED'; end if;
   select * into stock from public.stock_items where organization_id=org and id=unit_id for update;
   if stock.quantity<>1 or link.last_quantity<>1 or link.last_revision<>(unit->>'revision')::bigint then
    result:=result||jsonb_build_object('state','conflict','reason','CLOUD_STOCK_CONFLICT'); exit;
   end if;
  end loop;
  if result->>'state'='applied' then
   select jsonb_agg(jsonb_build_object('barcode',value->>'barcode','quantity',1)) into lines from jsonb_array_elements(payload->'items');
   receipt:=private.perform_sale(org,(payload->>'sale_id')::uuid,'physical','sic:'||source::text||':'||(payload->>'sale_id'),lines,null);
   result:=result||jsonb_build_object('cloud_sale_id',receipt->>'sale_id');
   for unit in select value from jsonb_array_elements(payload->'items') loop
    update public.sic_unit_links set last_revision=(unit->>'revision')::bigint+1,last_quantity=0,
      snapshot=unit||jsonb_build_object('quantity',0,'expected_quantity',0,'revision',(unit->>'revision')::bigint+1)
      where organization_id=org and stock_item_id=(unit->>'stock_item_id')::uuid;
   end loop;
  end if;
 end if;
 insert into public.sic_sync_events(organization_id,event_id,instance_id,request,result) values(org,event,source,p_event,result);
 return result;
end $$;
revoke all on function public.register_sic_connection(uuid,uuid,boolean),public.apply_sic_event(text,jsonb) from public,anon,authenticated;
grant execute on function public.register_sic_connection(uuid,uuid,boolean) to authenticated;
grant execute on function public.apply_sic_event(text,jsonb) to service_role;

-- Bound SIC companies must use the local catalog and desktop confirmation.
alter function public.create_product(uuid,uuid,jsonb) set schema private;
alter function private.create_product(uuid,uuid,jsonb) rename to cloud_create_product;
revoke all on function private.cloud_create_product(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
create function public.create_product(p_org uuid,p_request_id uuid,p_product jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
begin
 if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
 if exists(select 1 from public.sic_connections where organization_id=p_org and enabled) then raise exception 'LOCAL_CATALOG_REQUIRED'; end if;
 return private.cloud_create_product(p_org,p_request_id,p_product);
end $$;
revoke all on function public.create_product(uuid,uuid,jsonb) from public,anon;
grant execute on function public.create_product(uuid,uuid,jsonb) to authenticated;

create or replace function public.record_physical_sale(p_org uuid,p_key uuid,p_lines jsonb,p_reference text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
 if exists(select 1 from public.sic_connections where organization_id=p_org and enabled) then raise exception 'DESKTOP_CONFIRMATION_REQUIRED'; end if;
 return private.perform_sale(p_org,p_key,'physical',p_reference,p_lines,auth.uid());
end $$;
