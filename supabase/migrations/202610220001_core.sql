-- Client writes go through transactions below. RLS protects direct reads.
create schema if not exists private;
revoke all on schema private from public;
create sequence private.barcode_number maxvalue 999999999999;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  created_at timestamptz not null default now()
);
create table public.memberships (
  organization_id uuid not null references public.organizations(id),
  user_id uuid not null references auth.users(id),
  role text not null check (role in ('admin', 'operator')),
  primary key (organization_id, user_id)
);
create index memberships_user on public.memberships(user_id);
create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  email text not null check (email = lower(trim(email))),
  role text not null check (role in ('admin', 'operator')),
  invited_by uuid not null references auth.users(id),
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  unique (organization_id, email)
);
create table public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null check (length(trim(name)) between 1 and 160),
  category text not null default '', brand text not null default '', model text not null default '',
  tracking text not null check (tracking in ('quantity', 'individual')),
  notes text not null default '', photo_path text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
create table public.variants (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  product_id uuid not null,
  color text not null default '', size text not null default '',
  foreign key (organization_id, product_id) references public.products(organization_id, id),
  unique (organization_id, id), unique (organization_id, product_id, color, size)
);
create table public.stock_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  variant_id uuid not null,
  barcode text not null unique,
  tracking text not null check (tracking in ('quantity', 'individual')),
  quantity integer not null check (quantity >= 0 and (tracking = 'quantity' or quantity <= 1)),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, variant_id) references public.variants(organization_id, id),
  unique (organization_id, id)
);
create unique index stock_quantity_variant on public.stock_items(variant_id) where tracking = 'quantity';
create index stock_org on public.stock_items(organization_id);
create table public.catalog_requests (
  organization_id uuid not null references public.organizations(id),
  request_id uuid not null,
  payload jsonb not null,
  product_id uuid not null references public.products(id),
  primary key (organization_id, request_id)
);
create table public.sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  idempotency_key uuid not null,
  channel text not null check (channel in ('physical', 'ecommerce')),
  external_reference text,
  request jsonb not null,
  actor_id uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (organization_id, idempotency_key),
  unique (organization_id, channel, external_reference),
  unique (organization_id, id)
);
create table public.sale_lines (
  sale_id uuid not null,
  organization_id uuid not null,
  stock_item_id uuid not null,
  quantity integer not null check (quantity > 0),
  foreign key (organization_id, sale_id) references public.sales(organization_id, id),
  foreign key (organization_id, stock_item_id) references public.stock_items(organization_id, id),
  primary key (sale_id, stock_item_id)
);
create table public.stock_movements (
  id bigint generated always as identity primary key,
  organization_id uuid not null,
  stock_item_id uuid not null,
  delta integer not null check (delta <> 0),
  reason text not null check (reason in ('initial', 'sale')),
  sale_id uuid,
  actor_id uuid references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (organization_id, stock_item_id) references public.stock_items(organization_id, id),
  foreign key (organization_id, sale_id) references public.sales(organization_id, id)
);
create index movements_org on public.stock_movements(organization_id);
create table public.integration_keys (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null,
  token_hash text not null unique check (length(token_hash) = 64),
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create function private.is_member(org uuid, admin_only boolean default false)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.memberships
    where organization_id = org and user_id = (select auth.uid())
      and (not admin_only or role = 'admin'));
$$;
grant usage on schema private to authenticated;
grant execute on function private.is_member(uuid, boolean) to authenticated;

do $$
declare t text;
begin
  foreach t in array array['organizations','memberships','invitations','products','variants','stock_items',
    'catalog_requests','sales','sale_lines','stock_movements','integration_keys'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
  foreach t in array array['products','variants','stock_items','sales','sale_lines','stock_movements'] loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy tenant_read on public.%I for select to authenticated using (private.is_member(organization_id))', t);
  end loop;
end $$;
grant select on public.organizations, public.memberships to authenticated;
create policy tenant_read on public.organizations for select to authenticated using (private.is_member(id));
create policy tenant_read on public.memberships for select to authenticated using (private.is_member(organization_id));
grant select on public.invitations to authenticated;
create policy admin_read on public.invitations for select to authenticated using (private.is_member(organization_id, true));

-- No quantity in the mobile lookup/cache. Desktop/integrations read inventory separately.
create view public.mobile_catalog with (security_invoker = true) as
select s.organization_id, s.id as stock_item_id, s.barcode, s.tracking,
  p.id as product_id, p.name, p.category, p.brand, p.model, p.notes, p.photo_path,
  v.id as variant_id, v.color, v.size
from public.stock_items s
join public.variants v on v.id = s.variant_id and v.organization_id = s.organization_id
join public.products p on p.id = v.product_id and p.organization_id = v.organization_id;
grant select on public.mobile_catalog to authenticated;
create view public.inventory with (security_invoker = true) as
select c.*, s.quantity, s.updated_at from public.mobile_catalog c
join public.stock_items s on s.id = c.stock_item_id and s.organization_id = c.organization_id;
grant select on public.inventory to authenticated, service_role;
grant select on public.mobile_catalog, public.products, public.variants, public.stock_items to service_role;

create function public.accept_invitations() returns void
language plpgsql security definer set search_path = '' as $$
declare email_address text;
begin
  select lower(email) into email_address from auth.users where id = auth.uid() and email_confirmed_at is not null;
  if email_address is null then raise exception 'EMAIL_NOT_VERIFIED'; end if;
  insert into public.memberships(organization_id, user_id, role)
    select organization_id, auth.uid(), role from public.invitations
    where email = email_address and accepted_at is null and expires_at > now()
    on conflict do nothing;
  update public.invitations set accepted_at = now()
    where email = email_address and accepted_at is null and expires_at > now();
end $$;

create function public.prepare_invitation(p_org uuid, p_email text, p_role text default 'operator')
returns uuid language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if not private.is_member(p_org, true) then raise exception 'FORBIDDEN'; end if;
  if p_role not in ('admin','operator') or length(trim(p_email)) > 254
    or trim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'INVALID_INVITATION'; end if;
  if exists(select 1 from public.memberships m join auth.users u on u.id = m.user_id
    where m.organization_id = p_org and lower(u.email) = lower(trim(p_email))) then raise exception 'ALREADY_MEMBER'; end if;
  insert into public.invitations(organization_id, email, role, invited_by)
    values(p_org, lower(trim(p_email)), p_role, auth.uid())
    on conflict (organization_id, email) do update set role = excluded.role,
      invited_by = excluded.invited_by, expires_at = now() + interval '7 days', accepted_at = null
    returning id into result;
  return result;
end $$;

create function public.create_product(p_org uuid, p_request_id uuid, p_product jsonb)
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
  if mode is null or mode not in ('quantity','individual') or jsonb_typeof(p_product->'variants') is distinct from 'array'
    then raise exception 'INVALID_PRODUCT'; end if;
  if jsonb_array_length(p_product->'variants') not between 1 and 100 then raise exception 'INVALID_VARIANTS'; end if;
  if p_product->>'photo_path' is not null and (p_product->>'photo_path') not like p_org::text || '/%'
    then raise exception 'INVALID_PHOTO'; end if;
  insert into public.products(organization_id, name, category, brand, model, tracking, notes, photo_path, created_by)
    values(p_org, trim(p_product->>'name'), coalesce(p_product->>'category',''), coalesce(p_product->>'brand',''),
      coalesce(p_product->>'model',''), mode, coalesce(p_product->>'notes',''), p_product->>'photo_path', auth.uid())
    returning id into product;
  for v in select value from jsonb_array_elements(p_product->'variants') loop
    amount := (v->>'quantity')::integer;
    if amount is null or amount < 0 or amount > 100000 or (mode = 'individual' and amount not between 1 and 500)
      then raise exception 'INVALID_QUANTITY'; end if;
    insert into public.variants(organization_id, product_id, color, size)
      values(p_org, product, trim(coalesce(v->>'color','')), trim(coalesce(v->>'size',''))) returning id into variant;
    for n in 1..(case when mode = 'individual' then amount else 1 end) loop
      insert into public.stock_items(organization_id, variant_id, barcode, tracking, quantity)
        values(p_org, variant, 'SLB-' || lpad(nextval('private.barcode_number')::text, 12, '0'), mode,
          case when mode = 'individual' then 1 else amount end) returning id into item;
      if amount > 0 then
        insert into public.stock_movements(organization_id, stock_item_id, delta, reason, actor_id)
          values(p_org, item, case when mode = 'individual' then 1 else amount end, 'initial', auth.uid());
      end if;
    end loop;
  end loop;
  insert into public.catalog_requests values(p_org, p_request_id, p_product, product);
  return product;
end $$;

create function private.perform_sale(p_org uuid, p_key uuid, p_channel text, p_reference text, p_lines jsonb, p_actor uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare normalized jsonb; payload jsonb; existing public.sales; sale uuid; line jsonb; item public.stock_items;
begin
  if p_key is null or p_channel not in ('physical','ecommerce') or jsonb_typeof(p_lines) is distinct from 'array'
    then raise exception 'INVALID_SALE'; end if;
  if jsonb_array_length(p_lines) not between 1 and 200 then raise exception 'INVALID_LINES'; end if;
  for line in select value from jsonb_array_elements(p_lines) loop
    if (line->>'quantity') is null or (line->>'quantity') !~ '^[1-9][0-9]{0,5}$'
      or (line->>'barcode') is null or (line->>'barcode') !~ '^SLB-[0-9]{12}$' then raise exception 'INVALID_LINES'; end if;
  end loop;
  select jsonb_agg(jsonb_build_object('barcode', barcode, 'quantity', qty) order by barcode) into normalized
    from (select value->>'barcode' barcode, sum((value->>'quantity')::integer) qty
      from jsonb_array_elements(p_lines) group by value->>'barcode') x;
  payload := jsonb_build_object('channel', p_channel, 'reference', nullif(trim(p_reference),''), 'lines', normalized);
  perform pg_advisory_xact_lock(hashtextextended(p_org::text || p_key::text, 0));
  select * into existing from public.sales where organization_id = p_org and idempotency_key = p_key;
  if found then
    if existing.request <> payload then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return jsonb_build_object('sale_id', existing.id, 'replayed', true);
  end if;
  insert into public.sales(organization_id, idempotency_key, channel, external_reference, request, actor_id)
    values(p_org, p_key, p_channel, nullif(trim(p_reference),''), payload, p_actor) returning id into sale;
  -- Sorted locks prevent deadlocks between carts, including physical/e-commerce races.
  for line in select value from jsonb_array_elements(normalized) loop
    select * into item from public.stock_items where organization_id = p_org and barcode = line->>'barcode' for update;
    if not found then raise exception 'BARCODE_NOT_FOUND'; end if;
    if item.quantity < (line->>'quantity')::integer then raise exception 'INSUFFICIENT_STOCK'; end if;
    update public.stock_items set quantity = quantity - (line->>'quantity')::integer, updated_at = clock_timestamp() where id = item.id;
    insert into public.sale_lines values(sale, p_org, item.id, (line->>'quantity')::integer);
    insert into public.stock_movements(organization_id, stock_item_id, delta, reason, sale_id, actor_id)
      values(p_org, item.id, -(line->>'quantity')::integer, 'sale', sale, p_actor);
  end loop;
  return jsonb_build_object('sale_id', sale, 'replayed', false);
end $$;

create function public.record_physical_sale(p_org uuid, p_key uuid, p_lines jsonb, p_reference text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
  return private.perform_sale(p_org, p_key, 'physical', p_reference, p_lines, auth.uid());
end $$;

-- Metadata edits never rewrite identifiers, tracking mode or stock balances.
create function public.update_product(p_org uuid, p_product_id uuid, p_fields jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_member(p_org) then raise exception 'FORBIDDEN'; end if;
  update public.products set name = trim(p_fields->>'name'),
    category = coalesce(p_fields->>'category',''), brand = coalesce(p_fields->>'brand',''),
    model = coalesce(p_fields->>'model',''), notes = coalesce(p_fields->>'notes','')
    where organization_id = p_org and id = p_product_id;
  if not found then raise exception 'BARCODE_NOT_FOUND'; end if;
end $$;

create function public.add_integration_key(p_org uuid, p_name text, p_hash text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if not private.is_member(p_org, true) then raise exception 'FORBIDDEN'; end if;
  insert into public.integration_keys(organization_id, name, token_hash)
    values(p_org, p_name, p_hash) returning id into result;
  return result;
end $$;
create function public.revoke_integration_key(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.integration_keys set revoked_at = now() where id = p_id and private.is_member(organization_id, true);
  if not found then raise exception 'FORBIDDEN'; end if;
end $$;
create function public.integration_organization(p_hash text) returns uuid
language sql stable security definer set search_path = '' as $$
  select organization_id from public.integration_keys where token_hash = p_hash and revoked_at is null;
$$;
create function public.record_commerce_sale(p_hash text, p_key uuid, p_reference text, p_lines jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare org uuid;
begin
  org := public.integration_organization(p_hash);
  if org is null then raise exception 'FORBIDDEN'; end if;
  if nullif(trim(p_reference),'') is null then raise exception 'REFERENCE_REQUIRED'; end if;
  return private.perform_sale(org, p_key, 'ecommerce', p_reference, p_lines, null);
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_member(uuid, boolean) to authenticated;
revoke all on function public.accept_invitations(), public.prepare_invitation(uuid,text,text),
  public.create_product(uuid,uuid,jsonb), public.record_physical_sale(uuid,uuid,jsonb,text),
  public.update_product(uuid,uuid,jsonb),
  public.add_integration_key(uuid,text,text), public.revoke_integration_key(uuid),
  public.integration_organization(text), public.record_commerce_sale(text,uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.accept_invitations(), public.prepare_invitation(uuid,text,text),
  public.create_product(uuid,uuid,jsonb), public.record_physical_sale(uuid,uuid,jsonb,text),
  public.update_product(uuid,uuid,jsonb),
  public.add_integration_key(uuid,text,text), public.revoke_integration_key(uuid) to authenticated;
grant execute on function public.integration_organization(text), public.record_commerce_sale(text,uuid,text,jsonb) to service_role;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos','product-photos',false,5242880,array['image/jpeg','image/png','image/webp']);
create policy photo_read on storage.objects for select to authenticated
  using (bucket_id = 'product-photos' and private.is_member((storage.foldername(name))[1]::uuid));
create policy photo_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'product-photos' and private.is_member((storage.foldername(name))[1]::uuid));
create policy photo_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-photos' and private.is_member((storage.foldername(name))[1]::uuid));
