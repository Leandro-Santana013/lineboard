-- Existing and new products use barcode-only labels. The flag remains available for future QR-only products.
alter table public.stock_items add column qr_only boolean not null default false;
create or replace view public.mobile_catalog with (security_invoker = true) as
select s.organization_id, s.id as stock_item_id, s.barcode, s.tracking,
  p.id as product_id, p.name, p.category, p.brand, p.model, p.notes, p.photo_path,
  v.id as variant_id, v.color, v.size, s.qr_only
from public.stock_items s
join public.variants v on v.id = s.variant_id and v.organization_id = s.organization_id
join public.products p on p.id = v.product_id and p.organization_id = v.organization_id;

-- This is the current private implementation behind the public create_product wrapper.
create or replace function private.cloud_create_product(p_org uuid, p_request_id uuid, p_product jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare product uuid; variant uuid; item uuid; v jsonb; mode text; amount integer; n integer; previous public.catalog_requests;
begin
  if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_org::text || p_request_id::text, 0));
  select * into previous from public.catalog_requests where organization_id = p_org and request_id = p_request_id;
  if found then
    if previous.payload <> p_product then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return previous.product_id;
  end if;
  mode := p_product->>'tracking';
  if mode is null or mode not in ('quantity','individual') or jsonb_typeof(p_product->'variants') is distinct from 'array' then raise exception 'INVALID_PRODUCT'; end if;
  if jsonb_array_length(p_product->'variants') not between 1 and 100 then raise exception 'INVALID_VARIANTS'; end if;
  if p_product->>'photo_path' is not null and (p_product->>'photo_path') not like p_org::text || '/%' then raise exception 'INVALID_PHOTO'; end if;
  insert into public.products(organization_id, name, category, brand, model, tracking, notes, photo_path, created_by)
    values(p_org, trim(p_product->>'name'), coalesce(p_product->>'category',''), coalesce(p_product->>'brand',''),
      coalesce(p_product->>'model',''), mode, coalesce(p_product->>'notes',''), p_product->>'photo_path', auth.uid()) returning id into product;
  for v in select value from jsonb_array_elements(p_product->'variants') loop
    amount := (v->>'quantity')::integer;
    if amount is null or amount < 0 or amount > 100000 or (mode = 'individual' and amount not between 1 and 500) then raise exception 'INVALID_QUANTITY'; end if;
    insert into public.variants(organization_id, product_id, color, size)
      values(p_org, product, trim(coalesce(v->>'color','')), trim(coalesce(v->>'size',''))) returning id into variant;
    for n in 1..(case when mode = 'individual' then amount else 1 end) loop
      insert into public.stock_items(organization_id, variant_id, barcode, tracking, quantity, qr_only)
        values(p_org, variant, 'SLB-' || lpad(nextval('private.barcode_number')::text, 12, '0'), mode,
          case when mode = 'individual' then 1 else amount end, false) returning id into item;
      if amount > 0 then
        insert into public.stock_movements(organization_id, stock_item_id, delta, reason, actor_id)
          values(p_org, item, case when mode = 'individual' then 1 else amount end, 'initial', auth.uid());
      end if;
    end loop;
  end loop;
  insert into public.catalog_requests values(p_org, p_request_id, p_product, product);
  return product;
end $$;
revoke all on function private.cloud_create_product(uuid,uuid,jsonb) from public, anon, authenticated, service_role;

-- Carry the persisted label type through desktop SIC events without changing the scanner key.
alter function public.apply_sic_event(text,jsonb) set schema private;
alter function private.apply_sic_event(text,jsonb) rename to apply_sic_event_qr_core;
revoke all on function private.apply_sic_event_qr_core(text,jsonb) from public,anon,authenticated,service_role;
create function public.apply_sic_event(p_hash text,p_event jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; unit jsonb; org uuid; photo text; existing_product public.products; new_unit boolean;
begin
 org:=public.integration_organization(p_hash);
 if org is null then raise exception 'FORBIDDEN'; end if;
 perform pg_advisory_xact_lock(hashtextextended(org::text||':sic-sync',0));
 unit:=case when p_event->>'kind'='stock.adjusted' then p_event->'payload'->'unit' else p_event->'payload' end;
 if p_event->>'kind'='unit.upsert' then
  select * into existing_product from public.products where organization_id=org and id=(unit->>'product_id')::uuid;
  new_unit:=not exists(select 1 from public.sic_unit_links where organization_id=org and stock_item_id=(unit->>'stock_item_id')::uuid);
 end if;
 result:=private.apply_sic_event_qr_core(p_hash,p_event);
 if result->>'state'='applied' and coalesce((result->>'replayed')::boolean,false)=false and p_event->>'kind' in ('unit.upsert','stock.adjusted') then
  unit:=case when p_event->>'kind'='stock.adjusted' then p_event->'payload'->'unit' else p_event->'payload' end;
  if new_unit and unit ? 'qr_only' then
   update public.stock_items set qr_only=(unit->>'qr_only')::boolean where organization_id=org and id=(unit->>'stock_item_id')::uuid;
   update public.sic_unit_links set snapshot=snapshot||jsonb_build_object('qr_only',(unit->>'qr_only')::boolean) where organization_id=org and stock_item_id=(unit->>'stock_item_id')::uuid;
  end if;
  if unit ? 'photo_path' then
   photo:=nullif(unit->>'photo_path',''); perform private.validate_product_photo(org,photo);
   if new_unit and existing_product.id is not null and photo is distinct from existing_product.photo_path then
    update public.sic_unit_links set last_revision=last_revision+1,snapshot=snapshot||jsonb_build_object('photo_path',coalesce(existing_product.photo_path,''),'revision',last_revision+1)
      where organization_id=org and stock_item_id=(unit->>'stock_item_id')::uuid;
   else update public.products set photo_path=photo where organization_id=org and id=(unit->>'product_id')::uuid;
   end if;
  end if;
 end if;
 return result;
end $$;
revoke all on function public.apply_sic_event(text,jsonb) from public,anon,authenticated;
grant execute on function public.apply_sic_event(text,jsonb) to service_role;
