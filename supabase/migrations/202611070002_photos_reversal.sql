-- Keep the first image in photo_path for old clients and persist the complete
-- product gallery in tenant-scoped metadata. The desktop still uploads each
-- object through the photo function; this migration only stores references.
alter table public.products add column if not exists photo_paths jsonb not null default '[]'::jsonb;
update public.products
set photo_paths=jsonb_build_array(photo_path)
where photo_path is not null and photo_path<>'' and photo_paths='[]'::jsonb;

create or replace function private.validate_product_photos(p_org uuid,p_paths jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare path text;
begin
 if p_paths is null then return; end if;
 if jsonb_typeof(p_paths) is distinct from 'array' or jsonb_array_length(p_paths)>6 then raise exception 'INVALID_PHOTO'; end if;
 for path in select value from jsonb_array_elements_text(p_paths) loop
  perform private.validate_product_photo(p_org,nullif(path,''));
 end loop;
end $$;
revoke all on function private.validate_product_photos(uuid,jsonb) from public,anon,authenticated,service_role;

create or replace function public.create_product(p_org uuid,p_request_id uuid,p_product jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare product uuid; variant uuid; item uuid; v jsonb; mode text; amount integer; n integer; previous public.catalog_requests; photos jsonb; photo text;
begin
 if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_org::text||p_request_id::text,0));
 select * into previous from public.catalog_requests where organization_id=p_org and request_id=p_request_id;
 if found then
  if previous.payload<>p_product then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return previous.product_id;
 end if;
 mode:=p_product->>'tracking';
 if mode is null or mode not in ('quantity','individual') or jsonb_typeof(p_product->'variants') is distinct from 'array' then raise exception 'INVALID_PRODUCT'; end if;
 if jsonb_array_length(p_product->'variants') not between 1 and 100 then raise exception 'INVALID_VARIANTS'; end if;
 photos:=case when p_product ? 'photo_paths' then p_product->'photo_paths'
  when p_product ? 'photo_path' and nullif(p_product->>'photo_path','') is not null then jsonb_build_array(p_product->>'photo_path')
  else '[]'::jsonb end;
 perform private.validate_product_photos(p_org,photos);
 photo:=case when jsonb_array_length(photos)>0 then nullif(photos->>0,'') else null end;
 insert into public.products(organization_id,name,category,brand,model,tracking,notes,photo_path,photo_paths,created_by)
  values(p_org,trim(p_product->>'name'),coalesce(p_product->>'category',''),coalesce(p_product->>'brand',''),
   coalesce(p_product->>'model',''),mode,coalesce(p_product->>'notes',''),photo,photos,auth.uid())
  returning id into product;
 for v in select value from jsonb_array_elements(p_product->'variants') loop
  amount:=(v->>'quantity')::integer;
  if amount is null or amount<0 or amount>100000 or (mode='individual' and amount not between 1 and 500) then raise exception 'INVALID_QUANTITY'; end if;
  insert into public.variants(organization_id,product_id,color,size)
   values(p_org,product,trim(coalesce(v->>'color','')),trim(coalesce(v->>'size',''))) returning id into variant;
  for n in 1..(case when mode='individual' then amount else 1 end) loop
   insert into public.stock_items(organization_id,variant_id,barcode,tracking,quantity)
    values(p_org,variant,'SLB-'||lpad(nextval('private.barcode_number')::text,12,'0'),mode,case when mode='individual' then 1 else amount end)
    returning id into item;
   if amount>0 then
    insert into public.stock_movements(organization_id,stock_item_id,delta,reason,actor_id)
     values(p_org,item,case when mode='individual' then 1 else amount end,'initial',auth.uid());
   end if;
  end loop;
 end loop;
 insert into public.catalog_requests values(p_org,p_request_id,p_product,product);
 return product;
end $$;

create or replace function public.update_product(p_org uuid,p_product_id uuid,p_fields jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare before public.products; photo text; photos jsonb;
begin
 if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
 if jsonb_typeof(p_fields) is distinct from 'object' then raise exception 'INVALID_PRODUCT'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_org::text||':sic-sync',0));
 select * into before from public.products where organization_id=p_org and id=p_product_id for update;
 if not found then raise exception 'BARCODE_NOT_FOUND'; end if;
 photos:=before.photo_paths;
 if p_fields ? 'photo_paths' then photos:=p_fields->'photo_paths';
 elsif p_fields ? 'photo_path' then photos:=case when nullif(p_fields->>'photo_path','') is null then '[]'::jsonb else jsonb_build_array(nullif(p_fields->>'photo_path','')) end;
 end if;
 perform private.validate_product_photos(p_org,photos);
 photo:=case when jsonb_array_length(photos)>0 then nullif(photos->>0,'') else null end;
 if photo is distinct from before.photo_path or photos is distinct from before.photo_paths then
  if exists(select 1 from public.sic_checkout_claims where organization_id=p_org) then raise exception 'CHECKOUT_IN_PROGRESS'; end if;
  update public.sic_unit_links set last_revision=last_revision+1,
   snapshot=snapshot||jsonb_build_object('photo_path',coalesce(photo,''),'photo_paths',photos,'revision',last_revision+1)
   where organization_id=p_org and snapshot->>'product_id'=p_product_id::text;
 end if;
 update public.products set
  name=case when p_fields ? 'name' then trim(p_fields->>'name') else name end,
  category=case when p_fields ? 'category' then coalesce(p_fields->>'category','') else category end,
  brand=case when p_fields ? 'brand' then coalesce(p_fields->>'brand','') else brand end,
  model=case when p_fields ? 'model' then coalesce(p_fields->>'model','') else model end,
  notes=case when p_fields ? 'notes' then coalesce(p_fields->>'notes','') else notes end,
  photo_path=photo,photo_paths=photos
  where organization_id=p_org and id=p_product_id;
end $$;
revoke all on function public.update_product(uuid,uuid,jsonb) from public,anon;
grant execute on function public.update_product(uuid,uuid,jsonb) to authenticated;

-- Keep the catalog contract compatible while exposing the gallery to mobile.
create or replace view public.mobile_catalog with (security_invoker=true) as
select s.organization_id,s.id as stock_item_id,s.barcode,s.tracking,
 p.id as product_id,p.name,p.category,p.brand,p.model,p.notes,p.photo_path,
 v.id as variant_id,v.color,v.size,s.qr_only,p.photo_paths
from public.stock_items s
join public.variants v on v.id=s.variant_id and v.organization_id=s.organization_id
join public.products p on p.id=v.product_id and p.organization_id=v.organization_id;
grant select on public.mobile_catalog to authenticated;

alter table public.sales add column if not exists reversed_at timestamptz;
alter table public.sales add column if not exists reversal_request_id uuid;
alter table public.stock_movements drop constraint if exists stock_movements_reason_check;
alter table public.stock_movements add constraint stock_movements_reason_check check(reason in ('initial','sale','adjustment','sale_reversal'));

create or replace function private.reverse_sic_sale(p_org uuid,p_source uuid,p_event jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare sale public.sales; line public.sale_lines; item public.stock_items; link public.sic_unit_links; local_sale uuid; amount integer; result jsonb;
begin
 local_sale:=(p_event->'payload'->>'sale_id')::uuid;
 select * into sale from public.sales
  where organization_id=p_org and external_reference='sic:'||p_source::text||':'||local_sale::text for update;
 if not found then raise exception 'SALE_NOT_FOUND'; end if;
 if sale.reversed_at is not null then return jsonb_build_object('sale_id',sale.id,'reversed',true,'replayed',true); end if;
 for line in select * from public.sale_lines where organization_id=p_org and sale_id=sale.id order by stock_item_id for update loop
  amount:=line.quantity;
  select * into item from public.stock_items where organization_id=p_org and id=line.stock_item_id for update;
  if item.quantity<>0 then raise exception 'CLOUD_STOCK_CONFLICT'; end if;
  select * into link from public.sic_unit_links where organization_id=p_org and stock_item_id=item.id for update;
  if not found then raise exception 'UNIT_NOT_IMPORTED'; end if;
  update public.stock_items set quantity=quantity+amount,updated_at=clock_timestamp() where organization_id=p_org and id=item.id;
  insert into public.stock_movements(organization_id,stock_item_id,delta,reason,sale_id,actor_id)
    values(p_org,item.id,amount,'sale_reversal',sale.id,null);
  update public.sic_unit_links set last_quantity=item.quantity+amount,last_revision=last_revision+1,
    snapshot=snapshot||jsonb_build_object('quantity',item.quantity+amount,'expected_quantity',item.quantity+amount,'revision',last_revision+1)
    where organization_id=p_org and stock_item_id=item.id;
 end loop;
 update public.sales set reversed_at=now(),reversal_request_id=(p_event->>'event_id')::uuid where organization_id=p_org and id=sale.id;
 result:=jsonb_build_object('sale_id',sale.id,'reversed',true,'replayed',false);
 return result;
end $$;
revoke all on function private.reverse_sic_sale(uuid,uuid,jsonb) from public,anon,authenticated,service_role;

-- The previous public wrapper also projects photo metadata. Rebuild it as a
-- private helper so sale.reversed can be handled before the old core rejects
-- the new event kind.
alter function public.apply_sic_event(text,jsonb) set schema private;
alter function private.apply_sic_event(text,jsonb) rename to apply_sic_event_with_photos;
revoke all on function private.apply_sic_event_with_photos(text,jsonb) from public,anon,authenticated,service_role;

create or replace function private.apply_sic_event_with_photos(p_hash text,p_event jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; unit jsonb; org uuid; photo text; photos jsonb; existing_product public.products; new_unit boolean;
begin
 org:=public.integration_organization(p_hash); if org is null then raise exception 'FORBIDDEN'; end if;
 perform pg_advisory_xact_lock(hashtextextended(org::text||':sic-sync',0));
 unit:=case when p_event->>'kind'='stock.adjusted' then p_event->'payload'->'unit' else p_event->'payload' end;
 if p_event->>'kind'='unit.upsert' then
  select * into existing_product from public.products where organization_id=org and id=(unit->>'product_id')::uuid;
  new_unit:=not exists(select 1 from public.sic_unit_links where organization_id=org and stock_item_id=(unit->>'stock_item_id')::uuid);
 end if;
 result:=private.apply_sic_event_with_cart(p_hash,p_event);
 if result->>'state'='applied' and coalesce((result->>'replayed')::boolean,false)=false
    and p_event->>'kind' in ('unit.upsert','stock.adjusted') then
  unit:=case when p_event->>'kind'='stock.adjusted' then p_event->'payload'->'unit' else p_event->'payload' end;
  photos:=case when unit ? 'photo_paths' then unit->'photo_paths' when unit ? 'photo_path' and nullif(unit->>'photo_path','') is not null then jsonb_build_array(unit->>'photo_path') else '[]'::jsonb end;
  perform private.validate_product_photos(org,photos);
  photo:=case when jsonb_array_length(photos)>0 then nullif(photos->>0,'') else null end;
  if new_unit and existing_product.id is not null and (photo is distinct from existing_product.photo_path or photos is distinct from existing_product.photo_paths) then
   update public.sic_unit_links set last_revision=last_revision+1,
    snapshot=snapshot||jsonb_build_object('photo_path',coalesce(existing_product.photo_path,''),'photo_paths',existing_product.photo_paths,'revision',last_revision+1)
    where organization_id=org and stock_item_id=(unit->>'stock_item_id')::uuid;
  else
   update public.products set photo_path=photo,photo_paths=photos where organization_id=org and id=(unit->>'product_id')::uuid;
  end if;
 end if;
 return result;
end $$;
revoke all on function private.apply_sic_event_with_photos(text,jsonb) from public,anon,authenticated,service_role;

create function public.apply_sic_event(p_hash text,p_event jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare org uuid; source uuid; event uuid; kind text; result jsonb; previous public.sic_sync_events; connection public.sic_connections;
begin
 org:=public.integration_organization(p_hash); if org is null then raise exception 'FORBIDDEN'; end if;
 kind:=p_event->>'kind'; source:=(p_event->>'instance_id')::uuid; event:=(p_event->>'event_id')::uuid;
 if kind='sale.reversed' then
  if source is null or event is null or p_event->'payload' is null then raise exception 'INVALID_EVENT'; end if;
  perform pg_advisory_xact_lock(hashtextextended(org::text||':sic-sync',0));
  select * into connection from public.sic_connections where organization_id=org and instance_id=source and enabled for update;
  if not found then raise exception 'SIC_CONNECTION_NOT_REGISTERED'; end if;
  if p_event->>'mode' not in ('sandbox','production') then raise exception 'INVALID_EVENT_MODE'; end if;
  if p_event->>'mode'='sandbox' and not connection.allow_sandbox then raise exception 'SANDBOX_NOT_ALLOWED'; end if;
  select * into previous from public.sic_sync_events where organization_id=org and event_id=event;
  if found then
   if previous.request<>p_event then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
   return previous.result||jsonb_build_object('replayed',true);
  end if;
  result:=private.reverse_sic_sale(org,source,p_event)||jsonb_build_object('event_id',event,'state','applied');
  insert into public.sic_sync_events(organization_id,event_id,instance_id,request,result) values(org,event,source,p_event,result);
  return result;
 end if;
 return private.apply_sic_event_with_photos(p_hash,p_event);
end $$;
revoke all on function public.apply_sic_event(text,jsonb) from public,anon,authenticated;
grant execute on function public.apply_sic_event(text,jsonb) to service_role;
