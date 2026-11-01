import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

let db;
const adminA = randomUUID(), operator = randomUUID(), adminB = randomUUID(), invited = randomUUID();
const orgA = randomUUID(), orgB = randomUUID();
const hash = 'a'.repeat(64);
before(async () => {
  db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema storage;
    create table auth.users(id uuid primary key, email text, email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    grant usage on schema public,auth,storage to anon,authenticated,service_role;
    grant execute on function auth.uid() to anon,authenticated,service_role;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text);
    alter table storage.objects enable row level security;
    grant select,insert,delete on storage.objects to authenticated;
    create function storage.foldername(text) returns text[] language sql immutable as $$ select string_to_array($1,'/') $$;
  `);
  await db.exec(await readFile(new URL('../supabase/migrations/202610220001_core.sql', import.meta.url), 'utf8'));
  await db.query(`insert into auth.users values ($1,'admin@a.test',now()),($2,'operator@a.test',now()),($3,'admin@b.test',now()),($4,'invited@a.test',now())`, [adminA,operator,adminB,invited]);
  await db.query(`insert into organizations(id,name) values ($1,'Surf A'),($2,'Surf B')`, [orgA,orgB]);
  await db.query(`insert into memberships values ($1,$2,'admin'),($1,$3,'operator'),($4,$5,'admin')`, [orgA,adminA,operator,orgB,adminB]);
});
after(async () => { await db?.close(); });
async function as(user, role = 'authenticated') {
  await db.exec('reset role');
  await db.query(`select set_config('request.jwt.claim.sub',$1,false)`, [user ?? '']);
  await db.exec(`set role ${role}`);
}
async function product({ org = orgA, user = adminA, tracking = 'quantity', quantity = 5, variants, key = randomUUID(), extra = {} } = {}) {
  await as(user);
  const payload = {name: 'Leash', tracking, variants: variants ?? [{color:'Azul',size:'7 pés',quantity}], ...extra};
  const {rows} = await db.query('select create_product($1,$2,$3) id', [org,key,JSON.stringify(payload)]);
  const items = (await db.query('select * from mobile_catalog where product_id=$1 order by barcode', [rows[0].id])).rows;
  return {id:rows[0].id, items, payload, key};
}
async function sale(items, {key = randomUUID(), org = orgA, user = adminA, reference = null} = {}) {
  await as(user);
  return (await db.query('select record_physical_sale($1,$2,$3,$4) result', [org,key,JSON.stringify(items),reference])).rows[0].result;
}
async function quantity(code) { return (await db.query('select quantity from inventory where barcode=$1',[code])).rows[0]?.quantity; }

test('quantity: one globally unique Code 128 per variant and initial audit balance', async () => {
  const {items} = await product({variants:[{color:'Azul',size:'M',quantity:8},{color:'Azul',size:'G',quantity:2}]});
  assert.equal(items.length,2);
  assert.match(items[0].barcode,/^SLB-[0-9]{12}$/);
  assert.notEqual(items[0].barcode, items[1].barcode);
  assert.equal(await quantity(items[0].barcode),8);
  assert.equal('quantity' in items[0],false);
  const movements = (await db.query('select delta from stock_movements where stock_item_id=$1',[items[0].stock_item_id])).rows;
  assert.deepEqual(movements,[{delta:8}]);
});
test('individual: a distinct barcode for each physical unit, and never sell twice', async () => {
  const {items} = await product({tracking:'individual',quantity:3});
  assert.equal(new Set(items.map(i=>i.barcode)).size,3);
  await sale([{barcode:items[0].barcode,quantity:1}]);
  await assert.rejects(sale([{barcode:items[0].barcode,quantity:1}]),/INSUFFICIENT_STOCK/);
  assert.equal(await quantity(items[0].barcode),0);
});
test('create retry recovers same product/codes and rejects changed payload', async () => {
  const created = await product();
  const replay = await db.query('select create_product($1,$2,$3) id',[orgA,created.key,JSON.stringify(created.payload)]);
  assert.equal(replay.rows[0].id,created.id);
  await assert.rejects(db.query('select create_product($1,$2,$3)',[orgA,created.key,JSON.stringify({...created.payload,name:'Changed'})]),/IDEMPOTENCY_CONFLICT/);
});
test('invalid variant rolls back whole product, including initial movements', async () => {
  await as(adminA);
  const count = (await db.query('select count(*) n from products')).rows[0].n;
  await assert.rejects(product({variants:[{quantity:2},{quantity:-1}]}),/INVALID_QUANTITY|duplicate key/);
  assert.equal((await db.query('select count(*) n from products')).rows[0].n,count);
});
test('physical sale retries are idempotent and normalized repeated scans aggregate', async () => {
  const {items} = await product({quantity:10});
  const barcode = items[0].barcode, key = randomUUID();
  const first = await sale([{barcode,quantity:1},{barcode,quantity:2}],{key});
  const second = await sale([{barcode,quantity:3}],{key});
  assert.equal(first.sale_id,second.sale_id);
  assert.equal(second.replayed,true);
  assert.equal(await quantity(barcode),7);
  await assert.rejects(sale([{barcode,quantity:4}],{key}),/IDEMPOTENCY_CONFLICT/);
});
test('out-of-stock line rolls back all other lines and sale receipt', async () => {
  const a = (await product({quantity:5})).items[0], b = (await product({quantity:0})).items[0];
  const key = randomUUID();
  await assert.rejects(sale([{barcode:a.barcode,quantity:1},{barcode:b.barcode,quantity:1}],{key}),/INSUFFICIENT_STOCK/);
  assert.equal(await quantity(a.barcode),5);
  assert.equal((await db.query('select count(*) n from sales where idempotency_key=$1',[key])).rows[0].n,0);
});
test('unknown barcode is rejected without any movement', async () => {
  await assert.rejects(sale([{barcode:'SLB-999999999999',quantity:1}]),/BARCODE_NOT_FOUND/);
});
test('RLS blocks cross-store reads, writes, scans, sales and private photos', async () => {
  const a = (await product()).items[0];
  await product({org:orgB,user:adminB});
  await as(adminB);
  assert.equal((await db.query('select * from mobile_catalog where barcode=$1',[a.barcode])).rows.length,0);
  assert.equal((await db.query('select * from inventory where organization_id=$1',[orgA])).rows.length,0);
  await assert.rejects(sale([{barcode:a.barcode,quantity:1}],{org:orgA,user:adminB}),/FORBIDDEN/);
  await assert.rejects(sale([{barcode:a.barcode,quantity:1}],{org:orgB,user:adminB}),/BARCODE_NOT_FOUND/);
  await assert.rejects(product({org:orgA,user:adminB}),/FORBIDDEN/);
  await assert.rejects(db.query('update stock_items set quantity=100'),/permission denied/);
  await assert.rejects(db.query("insert into storage.objects(bucket_id,name) values ('product-photos',$1)",[`${orgA}/photo.jpg`]),/row-level security/);
});
test('operator can register but cannot invite or create integration secrets', async () => {
  const {items} = await product({user:operator});
  await sale([{barcode:items[0].barcode,quantity:1}],{user:operator});
  await assert.rejects(db.query("select prepare_invitation($1,'new@a.test','operator')",[orgA]),/FORBIDDEN/);
  await assert.rejects(db.query("select add_integration_key($1,'Shop',$2)",[orgA,hash]),/FORBIDDEN/);
});
test('invitation binds only a verified matching email; expired invite grants nothing', async () => {
  await as(adminA);
  await db.query("select prepare_invitation($1,'invited@a.test','operator')",[orgA]);
  await as(adminB);
  await db.query('select accept_invitations()');
  assert.equal((await db.query('select * from memberships where organization_id=$1',[orgA])).rows.length,0);
  await as(invited);
  await db.query('select accept_invitations()');
  assert.equal((await db.query('select role from memberships where user_id=$1',[invited])).rows[0].role,'operator');
  await as(adminA);
  await db.query("select prepare_invitation($1,'admin@b.test','operator')",[orgA]);
  await db.exec('reset role');
  await db.query("update invitations set expires_at=now()-interval '1 second' where email='admin@b.test'");
  await as(adminB);
  await db.query('select accept_invitations()');
  assert.equal((await db.query('select * from memberships where organization_id=$1',[orgA])).rows.length,0);
});
test('e-commerce shares central stock, retries safely and rejects duplicate order IDs', async () => {
  const {items} = await product({quantity:4});
  await db.query("select add_integration_key($1,'Shop',$2)",[orgA,hash]);
  await as(null,'service_role');
  const key=randomUUID(), lines=JSON.stringify([{barcode:items[0].barcode,quantity:2}]);
  const first=(await db.query('select record_commerce_sale($1,$2,$3,$4) result',[hash,key,'order-100',lines])).rows[0].result;
  const replay=(await db.query('select record_commerce_sale($1,$2,$3,$4) result',[hash,key,'order-100',lines])).rows[0].result;
  assert.equal(first.sale_id,replay.sale_id);
  await assert.rejects(db.query('select record_commerce_sale($1,$2,$3,$4)',[hash,randomUUID(),'order-100',lines]),/duplicate key/);
  await as(adminA);
  assert.equal(await quantity(items[0].barcode),2);
  await sale([{barcode:items[0].barcode,quantity:2}]);
  await as(null,'service_role');
  await assert.rejects(db.query('select record_commerce_sale($1,$2,$3,$4)',[hash,randomUUID(),'order-101',lines]),/INSUFFICIENT_STOCK/);
});
test('revoked integration and anonymous/private function calls are denied', async () => {
  await as(adminA);
  const id=(await db.query("select add_integration_key($1,'Revoked',$2) id",[orgA,'b'.repeat(64)])).rows[0].id;
  await db.query('select revoke_integration_key($1)',[id]);
  await as(null,'service_role');
  assert.equal((await db.query('select integration_organization($1) org',['b'.repeat(64)])).rows[0].org,null);
  await as(null,'anon');
  await assert.rejects(db.query('select create_product($1,$2,$3)',[orgA,randomUUID(),'{}']),/permission denied/);
  await as(adminA);
  await assert.rejects(db.query('select integration_organization($1)',[hash]),/permission denied/);
  await assert.rejects(db.query('select private.perform_sale($1,$2,$3,$4,$5,$6)',[orgA,randomUUID(),'ecommerce',null,'[]',adminA]),/permission denied/);
});
test('online metadata edit preserves barcode, tracking, variant and stock; other stores denied', async () => {
  const {id,items} = await product({quantity:7});
  const metadata={name:'Leash corrigido',category:'Acessórios',brand:'Surf',model:'Pro',notes:'Novo texto',quantity:999,tracking:'individual'};
  await db.query('select update_product($1,$2,$3)',[orgA,id,JSON.stringify(metadata)]);
  const item=(await db.query('select * from inventory where barcode=$1',[items[0].barcode])).rows[0];
  assert.equal(item.name,'Leash corrigido'); assert.equal(item.quantity,7); assert.equal(item.tracking,'quantity');
  assert.equal(item.variant_id,items[0].variant_id);
  await as(adminB);
  await assert.rejects(db.query('select update_product($1,$2,$3)',[orgA,id,JSON.stringify(metadata)]),/FORBIDDEN/);
});
