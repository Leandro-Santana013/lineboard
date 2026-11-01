-- Execute in the Supabase SQL editor AFTER creating the first administrator
-- in Authentication > Users > Invite user. Replace the email and store name.
-- Run once per company. Signup stays disabled; operators cannot create tenants.
do $$
declare administrator uuid; organization uuid; matches integer;
begin
  select id into administrator from auth.users where lower(email) = 'admin@sualoja.com.br';
  if administrator is null then raise exception 'Convide o administrador primeiro no painel Auth.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('lineboard-bootstrap:' || administrator::text, 0));
  select count(*), min(id::text)::uuid into matches, organization
    from public.organizations where name = 'Minha Surf Shop';
  if matches > 1 then raise exception 'Há várias lojas com esse nome. Selecione o UUID correto antes de vincular o administrador.'; end if;
  if organization is null then
    insert into public.organizations(name) values ('Minha Surf Shop') returning id into organization;
  end if;
  insert into public.memberships(organization_id,user_id,role) values(organization,administrator,'admin')
    on conflict (organization_id,user_id) do update set role='admin';
end $$;
