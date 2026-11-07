-- Restore tenant-scoped R2 validation: an uploaded private R2 object has no row in
-- storage.objects. Edge Functions verify/upload the object; this helper guards
-- the tenant and object name without coupling catalog/cart sync to Storage.
create or replace function private.validate_product_photo(p_org uuid,p_path text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_path is null or p_path='' then return; end if;
 if p_org is null or p_path !~ ('^'||p_org::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$')
 then raise exception 'INVALID_PHOTO'; end if;
end $$;

revoke all on function private.validate_product_photo(uuid,text) from public,anon,authenticated,service_role;
