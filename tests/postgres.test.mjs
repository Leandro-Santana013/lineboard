import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:net';
import EmbeddedPostgres from 'embedded-postgres';

let postgres, setup;
const user = randomUUID(), org = randomUUID();
const clients = [];
before(async () => {
  // An isolated, uniquely created temp cluster; never use existing user data.
  const directory = await realpath(await mkdtemp(join(tmpdir(),'lineboard-pg-')));
  const port = await new Promise(resolve => {
    const server = createServer(); server.listen(0,'127.0.0.1',() => { const p=server.address().port; server.close(()=>resolve(p)); });
  });
  postgres = new EmbeddedPostgres({databaseDir:join(directory,'cluster'),user:'postgres',password:'local-test-only',port,
    persistent:false,createPostgresUser:false,onLog:()=>{},onError:()=>{}});
  await postgres.initialise(); await postgres.start();
  setup = postgres.getPgClient(); await setup.connect();
  await setup.query(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema storage;
    create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    grant usage on schema public,auth,storage to anon,authenticated,service_role;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(bucket_id text,name text);
    alter table storage.objects enable row level security;
    create function storage.foldername(text) returns text[] language sql immutable as $$ select string_to_array($1,'/') $$;
  `);
  await setup.query(await readFile(new URL('../supabase/migrations/202610220001_core.sql',import.meta.url),'utf8'));
  await setup.query('insert into auth.users values ($1,$2,now())',[user,'race@test.local']);
  await setup.query('insert into organizations(id,name) values ($1,$2)',[org,'Race test']);
  await setup.query("insert into memberships values ($1,$2,'admin')",[org,user]);
  for (let i=0;i<2;i++) {
    const client=postgres.getPgClient(); await client.connect();
    await client.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);
    await client.query('set role authenticated'); clients.push(client);
  }
});
after(async () => {
  for (const client of clients) await client.end();
  await setup?.end(); await postgres?.stop();
});
async function create(quantity) {
  const result=await clients[0].query('select create_product($1,$2,$3) id',[org,randomUUID(),JSON.stringify({name:'Last board',tracking:'quantity',variants:[{quantity}]})]);
  return (await clients[0].query('select barcode from mobile_catalog where product_id=$1',[result.rows[0].id])).rows[0].barcode;
}
test('native Postgres: concurrent physical and commerce sales cannot sell the last piece twice', async () => {
  const barcode=await create(1), hash='c'.repeat(64);
  await clients[0].query("select add_integration_key($1,'Race',$2)",[org,hash]);
  await clients[1].query('reset role'); await clients[1].query('set role service_role');
  const lines=JSON.stringify([{barcode,quantity:1}]);
  const results=await Promise.allSettled([
    clients[0].query('select record_physical_sale($1,$2,$3,null)',[org,randomUUID(),lines]),
    clients[1].query('select record_commerce_sale($1,$2,$3,$4)',[hash,randomUUID(),'race-order',lines]),
  ]);
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
  assert.match(results.find(r=>r.status==='rejected').reason.message,/INSUFFICIENT_STOCK/);
  assert.equal((await setup.query('select quantity from stock_items where barcode=$1',[barcode])).rows[0].quantity,0);
  assert.equal((await setup.query("select count(*)::int n from stock_movements where delta=-1")).rows[0].n,1);
});
test('native Postgres: two concurrent submissions with same key yield one sale', async () => {
  await clients[1].query('reset role'); await clients[1].query('set role authenticated');
  const barcode=await create(3), key=randomUUID(), lines=JSON.stringify([{barcode,quantity:1}]);
  const results=await Promise.all(clients.map(c=>c.query('select record_physical_sale($1,$2,$3,null) result',[org,key,lines])));
  assert.equal(results[0].rows[0].result.sale_id,results[1].rows[0].result.sale_id);
  assert.deepEqual(results.map(r=>r.rows[0].result.replayed).sort(),[false,true]);
  assert.equal((await setup.query('select quantity from stock_items where barcode=$1',[barcode])).rows[0].quantity,2);
});

test('native Postgres: two store desktops racing to confirm a shared cart get exactly one claim',async()=>{
  const folder=new URL('../supabase/migrations/',import.meta.url);
  for(const file of (await readdir(folder)).filter(x=>x.endsWith('.sql')&&!x.startsWith('202610220001')).sort())await setup.query(await readFile(new URL(file,folder),'utf8'));
  const sharedOrg=randomUUID(),hash='f'.repeat(64),sources=[randomUUID(),randomUUID()],requests=[randomUUID(),randomUUID()];
  await setup.query("insert into organizations(id,name) values($1,'Shared race')",[sharedOrg]);
  await setup.query("insert into memberships values($1,$2,'admin')",[sharedOrg,user]);
  await clients[0].query("select add_integration_key($1,'Race',$2)",[sharedOrg,hash]);
  for(const source of sources)await setup.query('select switch_sic_connection($1,$2)',[hash,source]);
  const item={stock_item_id:randomUUID(),product_id:randomUUID(),variant_id:randomUUID(),barcode:'SLB-900001000001',name:'Concurrent shared piece',quantity:1,expected_quantity:1,revision:1};
  await setup.query('select apply_sic_event($1,$2)',[hash,JSON.stringify({event_id:randomUUID(),instance_id:sources[0],mode:'production',kind:'unit.upsert',payload:item})]);
  await clients[0].query('select update_sic_cart($1,$2,$3,$4)',[sharedOrg,randomUUID(),'add',item.barcode]);
  for(const client of clients){await client.query('reset role');await client.query('set role service_role');}
  const results=await Promise.allSettled(clients.map((client,i)=>client.query('select claim_sic_checkout($1,$2,$3,$4)',[hash,sources[i],requests[i],JSON.stringify([item])])));
  assert.equal(results.filter(x=>x.status==='fulfilled').length,1);
  assert.match(results.find(x=>x.status==='rejected').reason.message,/CHECKOUT_IN_PROGRESS/);
  assert.equal((await setup.query('select count(*)::int n from sic_checkout_claims where organization_id=$1',[sharedOrg])).rows[0].n,1);
  assert.equal((await setup.query('select quantity from stock_items where id=$1',[item.stock_item_id])).rows[0].quantity,1);
});
