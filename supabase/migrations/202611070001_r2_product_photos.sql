-- Product photos may now live in Cloudflare R2. The database keeps the
-- tenant-scoped reference, while the Edge Functions own object storage.
-- Existing Supabase Storage objects remain readable during the transition.
create or replace function private.validate_product_photo(p_org uuid,p_path text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_path is null or p_path='' then return; end if;
 if p_path !~ ('^'||p_org::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$')
 then raise exception 'INVALID_PHOTO'; end if;
end $$;

revoke all on function private.validate_product_photo(uuid,text) from public,anon,authenticated,service_role;
