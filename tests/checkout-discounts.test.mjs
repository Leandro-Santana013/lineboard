import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

let db, sequence = 0;
const org = randomUUID(), user = randomUUID(), source = randomUUID(), hash = 'd'.repeat(64);
async function database(includePending = true) {
  const connection = new PGlite();
  await connection.exec(`create role anon;create role authenticated;create role service_role bypassrls;
    create schema auth;create schema storage;
    create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema public,auth,storage to anon,authenticated,service_role;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text);
    alter table storage.objects enable row level security;grant select,insert,delete on storage.objects to authenticated;
    create function storage.foldername(text) returns text[] language sql immutable as $$select string_to_array($1,'/')$$;`);
  const folder = new URL('../supabase/migrations/', import.meta.url);
  for (const file of (await readdir(folder)).filter(x => x.endsWith('.sql')).sort()) {
    if (!includePending && /20261107000[23]_/.test(file)) continue;
    await connection.exec(await readFile(new URL(file, folder), 'utf8'));
  }
  await connection.query("insert into auth.users values($1,'discount@test',now())", [user]);
  await connection.query("insert into organizations(id,name) values($1,'Discounts')", [org]);
  await connection.query("insert into memberships values($1,$2,'admin')", [org, user]);
  await connection.query("select set_config('request.jwt.claim.sub',$1,false)", [user]);
  await connection.query("select add_integration_key($1,'Discounts',$2)", [org, hash]);
  await connection.exec('set role service_role');
  await connection.query('select switch_sic_connection($1,$2)', [hash, source]);
  await connection.exec('reset role');
  return connection;
}
before(async () => { db = await database(); });
after(async () => { await db?.close(); });
async function apply(value, connection = db) {
  await connection.exec('set role service_role');
  try { return (await connection.query('select apply_sic_event($1,$2) result', [hash, JSON.stringify(value)])).rows[0].result; }
  finally { await connection.exec('reset role'); }
}
async function sale(type = 'percent', value = 10, prices = [109,109,109,109], connection = db) {
  const items = [];
  for (const price of prices) {
    const item = { stock_item_id: randomUUID(), product_id: randomUUID(), variant_id: randomUUID(),
      barcode: `SLB-${900000600000 + ++sequence}`, name: 'Discount product', quantity: 1, expected_quantity: 1,
      revision: 1, price, cost: 10 };
    await apply({ event_id: randomUUID(), instance_id: source, mode: 'production', kind: 'unit.upsert', payload: item }, connection);
    items.push(item);
  }
  const subtotal = prices.reduce((sum, price) => sum + price, 0);
  const discount = type === 'percent' ? Math.round((subtotal * value / 100 + Number.EPSILON) * 100) / 100 : value;
  return { event_id: randomUUID(), instance_id: source, mode: 'production', kind: 'sale.confirmed',
    payload: { sale_id: randomUUID(), items, subtotal, discount_type: type, discount_value: value,
      discount_total: discount, total: Math.round((subtotal - discount) * 100) / 100 } };
}
test('percentage net total is persisted; replay does not charge or decrement stock twice', async () => {
  const event = await sale();
  const receipt = await apply(event);
  assert.equal(receipt.state, 'applied');
  const stored = (await db.query('select subtotal,discount_type,discount_value,discount_total,total from sales where id=$1', [receipt.cloud_sale_id])).rows[0];
  assert.deepEqual(stored, { subtotal:'436.00', discount_type:'percent', discount_value:'10.00', discount_total:'43.60', total:'392.40' });
  assert.equal((await apply(event)).replayed, true);
  assert.equal((await db.query('select count(*)::int n from stock_movements where sale_id=$1', [receipt.cloud_sale_id])).rows[0].n, 4);
  const changed = structuredClone(event); changed.payload.discount_value = 20;
  await assert.rejects(apply(changed), /IDEMPOTENCY_CONFLICT/);
});
test('fixed BRL, half-cent rounding, zero discount and 100 percent are supported', async () => {
  for (const [type,value,prices,expected] of [['amount',20.5,[109,109],197.5],['percent',10,[0.05],0.04],['percent',0,[109],109],['percent',100,[109],0]]) {
    const result = await apply(await sale(type,value,prices));
    const stored = (await db.query('select total from sales where id=$1',[result.cloud_sale_id])).rows[0];
    assert.equal(Number(stored.total),expected);
  }
});
test('invalid or tampered discounts roll back the entire sale and stock changes', async () => {
  for (const [type,value] of [['percent',101],['percent',-1],['amount',437],['amount',0.001],['other',1]]) {
    const event = await sale(type,value);
    await assert.rejects(apply(event), /INVALID_DISCOUNT/);
    assert.equal((await db.query('select count(*)::int n from sales where idempotency_key=$1',[event.payload.sale_id])).rows[0].n,0);
    for (const item of event.payload.items) assert.equal((await db.query('select quantity from stock_items where id=$1',[item.stock_item_id])).rows[0].quantity,1);
  }
  const event = await sale(); event.payload.total = 0;
  await assert.rejects(apply(event), /INVALID_DISCOUNT/);
});
test('discount metadata does not change the shared cart claim item identity', async () => {
  const event = await sale();
  for (const item of event.payload.items) await db.query('select update_sic_cart($1,$2,$3,$4)', [org,randomUUID(),'add',item.barcode]);
  const request = randomUUID();
  await db.query('select claim_sic_checkout($1,$2,$3,$4)',[hash,source,request,JSON.stringify(event.payload.items)]);
  event.payload.checkout_request_id = request;
  assert.equal((await apply(event)).state,'applied');
  assert.equal((await db.query('select count(*)::int n from sic_checkout_claims')).rows[0].n,0);
});
test('old desktop events remain valid without invented historical financial amounts', async () => {
  const event = await sale();
  for (const key of ['discount_type','discount_value','discount_total','subtotal']) delete event.payload[key];
  const result = await apply(event);
  assert.equal((await db.query('select total from sales where id=$1',[result.cloud_sale_id])).rows[0].total,null);
});
test('internal financial helper is not executable by application roles; sales RLS stays enabled', async () => {
  const rights = await db.query("select has_function_privilege('authenticated','private.record_sic_sale_financials(uuid,uuid,jsonb)','execute') allowed");
  assert.equal(rights.rows[0].allowed,false);
  assert.equal((await db.query("select relrowsecurity from pg_class where oid='public.sales'::regclass")).rows[0].relrowsecurity,true);
});
test('migration also works without unrelated pending photo/reversal/brand migrations', async () => {
  const connection = await database(false);
  try {
    const result = await apply(await sale('percent',10,[109,109,109,109],connection),connection);
    assert.equal((await connection.query('select total from sales where id=$1',[result.cloud_sale_id])).rows[0].total,'392.40');
  } finally { await connection.close(); }
});
