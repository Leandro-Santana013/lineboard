-- Notify authenticated mobile clients and Windows adapters when the shared
-- cart version changes. The payload is only a version marker; consumers pull
-- the canonical snapshot through the existing RPC/sic-sync paths.
grant select on public.sic_shared_carts to authenticated;

drop policy if exists sic_shared_cart_version_read on public.sic_shared_carts;
create policy sic_shared_cart_version_read
 on public.sic_shared_carts
 for select to authenticated
 using (private.is_member(organization_id));

do $$
begin
 if exists (select 1 from pg_publication where pubname='supabase_realtime')
    and not exists (
      select 1 from pg_publication_tables
       where pubname='supabase_realtime'
         and schemaname='public'
         and tablename='sic_shared_carts'
    ) then
   execute 'alter publication supabase_realtime add table public.sic_shared_carts';
 end if;
end $$;
