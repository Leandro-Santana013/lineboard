-- Keep the current store's brand spelling consistent across the cloud catalog
-- and the SIC snapshot consumed by the desktop/mobile bridge.
do $$
declare
  target_org uuid;
begin
  select id into target_org
  from public.organizations
  where name = 'Leandro Santana'
  order by created_at
  limit 1;

  if target_org is null then
    return;
  end if;

  update public.products
  set brand = 'Lines'
  where organization_id = target_org
    and lower(trim(brand)) = 'lines'
    and brand is distinct from 'Lines';

  update public.sic_unit_links
  set snapshot = snapshot || jsonb_build_object('brand', 'Lines')
  where organization_id = target_org
    and snapshot ? 'brand'
    and lower(trim(snapshot->>'brand')) = 'lines'
    and snapshot->>'brand' is distinct from 'Lines';
end $$;
