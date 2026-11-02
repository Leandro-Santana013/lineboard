-- One canonical cart per organization. A scan changes the cart, never stock.
create table public.sic_shared_carts (
 organization_id uuid primary key references public.organizations(id),
 version bigint not null default 0,
 updated_at timestamptz not null default now()
);
create table public.sic_shared_cart_items (
 organization_id uuid not null references public.organizations(id),
 stock_item_id uuid not null,
 added_at timestamptz not null default now(),
 primary key(organization_id,stock_item_id),
 foreign key(organization_id,stock_item_id) references public.stock_items(organization_id,id)
);
create table public.sic_cart_requests (
 organization_id uuid not null references public.organizations(id),
 request_id uuid not null, action text not null, barcode text not null, result jsonb not null,
 primary key(organization_id,request_id)
);
-- No automatic expiry: an uncertain local commit must not free a sold piece.
create table public.sic_checkout_claims (
 organization_id uuid not null references public.organizations(id),
 request_id uuid not null, instance_id uuid not null, items jsonb not null,
 created_at timestamptz not null default now(),
 primary key(organization_id,request_id),
 unique(organization_id),
 foreign key(organization_id,instance_id) references public.sic_connections(organization_id,instance_id)
);
do $$ declare t text; begin
 foreach t in array array['sic_shared_carts','sic_shared_cart_items','sic_cart_requests','sic_checkout_claims'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
 end loop;
end $$;

create function private.sic_cart_snapshot(p_org uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('version',coalesce((select version from public.sic_shared_carts where organization_id=p_org),0),
 'barcodes',coalesce((select jsonb_agg(s.barcode order by s.barcode) from public.sic_shared_cart_items c
 join public.stock_items s on s.organization_id=c.organization_id and s.id=c.stock_item_id where c.organization_id=p_org),'[]'::jsonb),
 'items',coalesce((select jsonb_agg(l.snapshot order by s.barcode) from public.sic_shared_cart_items c
 join public.stock_items s on s.organization_id=c.organization_id and s.id=c.stock_item_id
 join public.sic_unit_links l on l.organization_id=c.organization_id and l.stock_item_id=c.stock_item_id where c.organization_id=p_org),'[]'::jsonb));
$$;
revoke all on function private.sic_cart_snapshot(uuid) from public,anon,authenticated,service_role;

create function private.change_sic_cart(p_org uuid,p_request uuid,p_action text,p_barcode text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prev public.sic_cart_requests; item public.stock_items; changed integer; result jsonb;
begin
 if p_request is null or p_action not in ('add','remove') or p_action is null or p_barcode is null or p_barcode !~ '^SLB-[0-9]{12}$' then raise exception 'INVALID_COMMAND'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_org::text||':sic-sync',0));
 select * into prev from public.sic_cart_requests where organization_id=p_org and request_id=p_request;
 if found then
  if prev.action<>p_action or prev.barcode<>p_barcode then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return prev.result||jsonb_build_object('replayed',true);
 end if;
 if exists(select 1 from public.sic_checkout_claims where organization_id=p_org) then raise exception 'CHECKOUT_IN_PROGRESS'; end if;
 select * into item from public.stock_items where organization_id=p_org and barcode=p_barcode for update;
 if not found then raise exception 'BARCODE_NOT_FOUND'; end if;
 if p_action='add' then
  if item.quantity<>1 then raise exception 'INSUFFICIENT_STOCK'; end if;
  insert into public.sic_shared_cart_items(organization_id,stock_item_id) values(p_org,item.id) on conflict do nothing;
 else
  delete from public.sic_shared_cart_items where organization_id=p_org and stock_item_id=item.id;
 end if;
 get diagnostics changed=row_count;
 insert into public.sic_shared_carts(organization_id,version) values(p_org,changed)
 on conflict(organization_id) do update set version=public.sic_shared_carts.version+changed,updated_at=now();
 result:=private.sic_cart_snapshot(p_org)||jsonb_build_object('state','saved','replayed',false);
 insert into public.sic_cart_requests values(p_org,p_request,p_action,p_barcode,result);
 return result;
end $$;
revoke all on function private.change_sic_cart(uuid,uuid,text,text) from public,anon,authenticated,service_role;

create function public.update_sic_cart(p_org uuid,p_request_id uuid,p_action text,p_barcode text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
 if not exists(select 1 from public.sic_connections where organization_id=p_org and enabled) then raise exception 'SIC_CONNECTION_NOT_REGISTERED'; end if;
 return private.change_sic_cart(p_org,p_request_id,p_action,p_barcode);
end $$;
create function public.read_sic_cart(p_org uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
 return private.sic_cart_snapshot(p_org);
end $$;
revoke all on function public.update_sic_cart(uuid,uuid,text,text),public.read_sic_cart(uuid) from public,anon;
grant execute on function public.update_sic_cart(uuid,uuid,text,text),public.read_sic_cart(uuid) to authenticated;

create function public.read_sic_snapshot(p_hash text,p_instance uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare org uuid; units jsonb;
begin
 org:=public.integration_organization(p_hash); if org is null then raise exception 'FORBIDDEN'; end if;
 perform pg_advisory_xact_lock(hashtextextended(org::text||':sic-sync',0));
 perform public.switch_sic_connection(p_hash,p_instance);
 select coalesce(jsonb_agg(snapshot order by stock_item_id),'[]'::jsonb) into units from public.sic_unit_links where organization_id=org;
 return jsonb_build_object('state','snapshot','organization_id',org,'instance_id',p_instance,'units',units,'count',jsonb_array_length(units),'cart',private.sic_cart_snapshot(org));
end $$;
revoke all on function public.read_sic_snapshot(text,uuid) from public,anon,authenticated;
grant execute on function public.read_sic_snapshot(text,uuid) to service_role;

create function public.claim_sic_checkout(p_hash text,p_instance uuid,p_request uuid,p_items jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare org uuid; prev public.sic_checkout_claims; unit jsonb; link public.sic_unit_links; stock public.stock_items;
begin
 org:=public.integration_organization(p_hash); if org is null then raise exception 'FORBIDDEN'; end if;
 if p_request is null or jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)=0 then raise exception 'INVALID_LINES'; end if;
 perform pg_advisory_xact_lock(hashtextextended(org::text||':sic-sync',0));
 if not exists(select 1 from public.sic_connections where organization_id=org and instance_id=p_instance and enabled) then raise exception 'SIC_CONNECTION_NOT_REGISTERED'; end if;
 select * into prev from public.sic_checkout_claims where organization_id=org;
 if found then
  if prev.request_id=p_request and prev.instance_id=p_instance and prev.items=p_items then return jsonb_build_object('state','claimed','request_id',p_request,'replayed',true); end if;
  raise exception 'CHECKOUT_IN_PROGRESS';
 end if;
 if (select coalesce(jsonb_agg(value->>'barcode' order by value->>'barcode'),'[]'::jsonb) from jsonb_array_elements(p_items)) <> private.sic_cart_snapshot(org)->'barcodes' then raise exception 'CART_CHANGED'; end if;
 for unit in select value from jsonb_array_elements(p_items) loop
  select * into link from public.sic_unit_links where organization_id=org and stock_item_id=(unit->>'stock_item_id')::uuid;
  if not found then raise exception 'UNIT_NOT_IMPORTED'; end if;
  select * into stock from public.stock_items where organization_id=org and id=link.stock_item_id for update;
  if stock.quantity<>1 or link.last_quantity<>1 or link.last_revision is distinct from (unit->>'revision')::bigint or stock.barcode is distinct from unit->>'barcode' then raise exception 'CLOUD_STOCK_CONFLICT'; end if;
 end loop;
 insert into public.sic_checkout_claims(organization_id,request_id,instance_id,items) values(org,p_request,p_instance,p_items);
 return jsonb_build_object('state','claimed','request_id',p_request,'replayed',false);
end $$;
create function public.release_sic_checkout(p_hash text,p_instance uuid,p_request uuid) returns void
language plpgsql security definer set search_path='' as $$
declare org uuid;
begin
 org:=public.integration_organization(p_hash); if org is null then raise exception 'FORBIDDEN'; end if;
 perform pg_advisory_xact_lock(hashtextextended(org::text||':sic-sync',0));
 delete from public.sic_checkout_claims where organization_id=org and instance_id=p_instance and request_id=p_request;
end $$;
revoke all on function public.claim_sic_checkout(text,uuid,uuid,jsonb),public.release_sic_checkout(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.claim_sic_checkout(text,uuid,uuid,jsonb),public.release_sic_checkout(text,uuid,uuid) to service_role;

-- Retain the stock/sale transaction and fix the former single-source sale guard.
alter function public.apply_sic_event(text,jsonb) set schema private;
alter function private.apply_sic_event(text,jsonb) rename to apply_sic_event_core;
do $$ declare definition text; begin
 select pg_get_functiondef('private.apply_sic_event_core(text,jsonb)'::regprocedure) into definition;
 if position('and instance_id=source for update' in definition)=0 then raise exception 'SIC_SALE_SOURCE_GUARD_NOT_FOUND'; end if;
 definition:=replace(definition,'and instance_id=source for update','for update');
 execute definition;
end $$;
revoke all on function private.apply_sic_event_core(text,jsonb) from public,anon,authenticated,service_role;

create function public.apply_sic_event(p_hash text,p_event jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare org uuid; source uuid; event uuid; kind text; result jsonb; prev public.sic_sync_events; claim public.sic_checkout_claims;
begin
 org:=public.integration_organization(p_hash); if org is null then raise exception 'FORBIDDEN'; end if;
 source:=(p_event->>'instance_id')::uuid; event:=(p_event->>'event_id')::uuid; kind:=p_event->>'kind';
 if source is null or event is null then raise exception 'INVALID_EVENT'; end if;
 perform pg_advisory_xact_lock(hashtextextended(org::text||':sic-sync',0));
 if not exists(select 1 from public.sic_connections where organization_id=org and instance_id=source and enabled) then raise exception 'SIC_CONNECTION_NOT_REGISTERED'; end if;
 if p_event->>'mode' not in ('sandbox','production') or p_event->>'mode' is null then raise exception 'INVALID_EVENT_MODE'; end if;
 if p_event->>'mode'='sandbox' and not exists(select 1 from public.sic_connections where organization_id=org and instance_id=source and allow_sandbox) then raise exception 'SANDBOX_NOT_ALLOWED'; end if;
 select * into prev from public.sic_sync_events where organization_id=org and event_id=event;
 if found then
  if prev.request<>p_event then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return prev.result||jsonb_build_object('replayed',true);
 end if;
 if kind in ('cart.added','cart.removed') then
  result:=private.change_sic_cart(org,event,case when kind='cart.added' then 'add' else 'remove' end,p_event->'payload'->>'barcode');
  result:=result||jsonb_build_object('event_id',event,'state','applied');
  insert into public.sic_sync_events(organization_id,event_id,instance_id,request,result) values(org,event,source,p_event,result);
  return result;
 end if;
 select * into claim from public.sic_checkout_claims where organization_id=org;
 if found and (kind<>'sale.confirmed' or claim.instance_id<>source or claim.request_id is distinct from (p_event->'payload'->>'checkout_request_id')::uuid or claim.items<>p_event->'payload'->'items') then raise exception 'CHECKOUT_IN_PROGRESS'; end if;
 if kind='sale.confirmed' and p_event->'payload' ? 'checkout_request_id' and claim.request_id is null then raise exception 'CHECKOUT_CLAIM_REQUIRED'; end if;
 result:=private.apply_sic_event_core(p_hash,p_event);
 if kind='sale.confirmed' and result->>'state'='applied' then
  delete from public.sic_checkout_claims where organization_id=org and instance_id=source and request_id=(p_event->'payload'->>'checkout_request_id')::uuid;
 end if;
 return result;
end $$;
revoke all on function public.apply_sic_event(text,jsonb) from public,anon,authenticated;
grant execute on function public.apply_sic_event(text,jsonb) to service_role;

-- A stock decrement removes a sold/unavailable unit from the shared cart.
create function private.sic_cart_stock_changed() returns trigger
language plpgsql security definer set search_path='' as $$
declare changed integer;
begin
 if new.quantity=0 then
  delete from public.sic_shared_cart_items where organization_id=new.organization_id and stock_item_id=new.id;
  get diagnostics changed=row_count;
  if changed>0 then update public.sic_shared_carts set version=version+1,updated_at=now() where organization_id=new.organization_id; end if;
 end if;
 return new;
end $$;
create trigger sic_cart_stock_changed after update of quantity on public.stock_items for each row execute function private.sic_cart_stock_changed();
revoke all on function private.sic_cart_stock_changed() from public,anon,authenticated,service_role;

-- Mobile may prepare the common cart; the final sale requires desktop review.
do $$ declare definition text; guard text:='if not private.is_member(p_org) then raise exception ''FORBIDDEN''; end if;'; begin
 select pg_get_functiondef('public.queue_sic_command(uuid,uuid,uuid,text,jsonb)'::regprocedure) into definition;
 if position(guard in definition)=0 then raise exception 'SIC_COMMAND_MEMBERSHIP_GUARD_NOT_FOUND'; end if;
 definition:=replace(definition,guard,guard||E'\n  if p_kind=''cart.confirm'' then raise exception ''DESKTOP_CONFIRMATION_REQUIRED''; end if;');
 execute definition;
end $$;
