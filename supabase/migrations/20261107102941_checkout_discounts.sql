-- Nullable amounts preserve historical sales whose financial details were not captured.
alter table public.sales
 add column subtotal numeric(19,2),
 add column discount_type text,
 add column discount_value numeric(19,2),
 add column discount_total numeric(19,2),
 add column total numeric(19,2),
 add constraint sales_discount_amounts check (
  (subtotal is null and discount_type is null and discount_value is null and discount_total is null and total is null)
  or (subtotal is not null and discount_type is not null and discount_value is not null and discount_total is not null and total is not null
   and subtotal > 0 and discount_type in ('percent','amount') and discount_value >= 0
   and discount_total between 0 and subtotal and total = subtotal-discount_total
   and ((discount_type='percent' and discount_value <= 100 and discount_total=round(subtotal*discount_value/100,2))
    or (discount_type='amount' and discount_value=discount_total)))
 );

-- Only the authenticated SIC event pipeline calls this helper. No public RPC or new grants.
create function private.record_sic_sale_financials(p_org uuid,p_sale uuid,p_payload jsonb)
returns void language plpgsql set search_path='' as $$
declare
 kind text; value numeric; gross numeric; deduction numeric; net numeric;
begin
 if not (p_payload ? 'discount_type') then return; end if; -- Older desktop versions.
 kind:=p_payload->>'discount_type';
 if kind is null or kind not in ('percent','amount')
  or jsonb_typeof(p_payload->'discount_value') is distinct from 'number'
  or jsonb_typeof(p_payload->'subtotal') is distinct from 'number'
  or jsonb_typeof(p_payload->'discount_total') is distinct from 'number'
  or jsonb_typeof(p_payload->'total') is distinct from 'number'
  then raise exception 'INVALID_DISCOUNT'; end if;
 value:=(p_payload->>'discount_value')::numeric;
 if value<0 or value<>round(value,2) or (kind='percent' and value>100)
  then raise exception 'INVALID_DISCOUNT'; end if;
 if exists(select 1 from jsonb_array_elements(p_payload->'items') x
  where jsonb_typeof(x->'price') is distinct from 'number' or (x->>'price')::numeric<0)
  then raise exception 'INVALID_DISCOUNT'; end if;
 select sum(round((x->>'price')::numeric,2)) into gross from jsonb_array_elements(p_payload->'items') x;
 if gross is null or gross<=0 or (kind='amount' and value>gross) then raise exception 'INVALID_DISCOUNT'; end if;
 deduction:=case when kind='percent' then round(gross*value/100,2) else value end;
 net:=gross-deduction;
 if (p_payload->>'subtotal')::numeric<>gross or (p_payload->>'discount_total')::numeric<>deduction
  or (p_payload->>'total')::numeric<>net then raise exception 'INVALID_DISCOUNT'; end if;
 update public.sales set subtotal=gross,discount_type=kind,discount_value=value,discount_total=deduction,total=net
  where organization_id=p_org and id=p_sale;
 if not found then raise exception 'INVALID_SALE'; end if;
end $$;
revoke all on function private.record_sic_sale_financials(uuid,uuid,jsonb) from public,anon,authenticated,service_role;

-- Keep the existing claim, stock, tenant isolation and event replay checks untouched.
do $$
declare definition text; anchor text:='result:=result||jsonb_build_object(''cloud_sale_id'',receipt->>''sale_id'');';
begin
 definition:=pg_get_functiondef('private.apply_sic_event_core(text,jsonb)'::regprocedure);
 if position(anchor in definition)=0 then raise exception 'SIC_SALE_FUNCTION_CHANGED'; end if;
 definition:=replace(definition,anchor,
  'perform private.record_sic_sale_financials(org,(receipt->>''sale_id'')::uuid,payload);'||chr(10)||'   '||anchor);
 execute definition;
end $$;
