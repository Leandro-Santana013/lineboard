-- A photo is a private Storage object, shared by the product's variants.
-- Never persist expiring signed URLs or accept a different store's object.
create function private.validate_product_photo(p_org uuid,p_path text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_path is null or p_path='' then return; end if;
 if p_path !~ ('^'||p_org::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$')
   or not exists(select 1 from storage.objects where bucket_id='product-photos' and name=p_path)
 then raise exception 'INVALID_PHOTO'; end if;
end $$;
revoke all on function private.validate_product_photo(uuid,text) from public,anon,authenticated,service_role;

-- Preserve the existing cart/checkout and stock transaction before projecting
-- photo metadata. A replay/old/conflicting event must never undo a later photo.
alter function public.apply_sic_event(text,jsonb) set schema private;
alter function private.apply_sic_event(text,jsonb) rename to apply_sic_event_with_cart;
revoke all on function private.apply_sic_event_with_cart(text,jsonb) from public,anon,authenticated,service_role;

create function public.apply_sic_event(p_hash text,p_event jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; unit jsonb; org uuid; photo text; existing_product public.products; new_unit boolean;
begin
 -- A phone can replace a photo after the first unit of a new product has
 -- arrived, while later initial units are still queued on its desktop.
 -- Those initial events must inherit the current product photo.
 org:=public.integration_organization(p_hash);
 if org is null then raise exception 'FORBIDDEN'; end if;
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
  if unit ? 'photo_path' then
   photo:=nullif(unit->>'photo_path','');
   perform private.validate_product_photo(org,photo);
   if new_unit and existing_product.id is not null and photo is distinct from existing_product.photo_path then
    update public.sic_unit_links set last_revision=last_revision+1,
      snapshot=snapshot||jsonb_build_object('photo_path',coalesce(existing_product.photo_path,''),'revision',last_revision+1)
      where organization_id=org and stock_item_id=(unit->>'stock_item_id')::uuid;
   else
    update public.products set photo_path=photo where organization_id=org and id=(unit->>'product_id')::uuid;
   end if;
  end if;
 end if;
 return result;
end $$;
revoke all on function public.apply_sic_event(text,jsonb) from public,anon,authenticated;
grant execute on function public.apply_sic_event(text,jsonb) to service_role;

create or replace function public.update_product(p_org uuid,p_product_id uuid,p_fields jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare before public.products; photo text;
begin
 if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
 if jsonb_typeof(p_fields) is distinct from 'object' then raise exception 'INVALID_PRODUCT'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_org::text||':sic-sync',0));
 select * into before from public.products where organization_id=p_org and id=p_product_id for update;
 if not found then raise exception 'BARCODE_NOT_FOUND'; end if;
 photo:=before.photo_path;
 if p_fields ? 'photo_path' then
  if jsonb_typeof(p_fields->'photo_path') not in ('string','null') then raise exception 'INVALID_PHOTO'; end if;
  photo:=nullif(p_fields->>'photo_path','');
  perform private.validate_product_photo(p_org,photo);
 end if;
 if photo is distinct from before.photo_path then
  if exists(select 1 from public.sic_checkout_claims where organization_id=p_org) then raise exception 'CHECKOUT_IN_PROGRESS'; end if;
  -- Each desktop imports only a newer revision. Keep quantity and all stock
  -- identifiers intact, including when removing the optional image.
  update public.sic_unit_links set last_revision=last_revision+1,
   snapshot=snapshot||jsonb_build_object('photo_path',coalesce(photo,''),'revision',last_revision+1)
   where organization_id=p_org and snapshot->>'product_id'=p_product_id::text;
 end if;
 update public.products set
  name=case when p_fields ? 'name' then trim(p_fields->>'name') else name end,
  category=case when p_fields ? 'category' then coalesce(p_fields->>'category','') else category end,
  brand=case when p_fields ? 'brand' then coalesce(p_fields->>'brand','') else brand end,
  model=case when p_fields ? 'model' then coalesce(p_fields->>'model','') else model end,
  notes=case when p_fields ? 'notes' then coalesce(p_fields->>'notes','') else notes end,
  photo_path=photo
  where organization_id=p_org and id=p_product_id;
end $$;
revoke all on function public.update_product(uuid,uuid,jsonb) from public,anon;
grant execute on function public.update_product(uuid,uuid,jsonb) to authenticated;
