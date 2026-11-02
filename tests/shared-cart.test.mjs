import {test, before, after} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';

let db;
const org=randomUUID(), otherOrg=randomUUID(), user=randomUUID(), outsider=randomUUID();
const first=randomUUID(), second=randomUUID(), hash='d'.repeat(64), otherHash='e'.repeat(64);
let sequence=0;
before(async()=>{
 db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create schema storage;
 create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema public,auth,storage to anon,authenticated,service_role;
 create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text);
 alter table storage.objects enable row level security; grant select,insert,delete on storage.objects to authenticated;
 create function storage.foldername(text) returns text[] language sql immutable as $$select string_to_array($1,'/')$$;`);
 const folder=new URL('../supabase/migrations/',import.meta.url);
 for(const file of (await readdir(folder)).filter(x=>x.endsWith('.sql')).sort())await db.exec(await readFile(new URL(file,folder),'utf8'));
 await db.query("insert into auth.users values($1,'shared@test',now()),($2,'other@test',now())",[user,outsider]);
 await db.query("insert into organizations(id,name) values($1,'Shared'),($2,'Other')",[org,otherOrg]);
 await db.query("insert into memberships values($1,$2,'admin'),($3,$4,'admin')",[org,user,otherOrg,outsider]);
 await as(user);await db.query("select add_integration_key($1,'Shared',$2)",[org,hash]);
 await as(outsider);await db.query("select add_integration_key($1,'Other',$2)",[otherOrg,otherHash]);
 await as(null,'service_role');
 for(const source of [first,second])await db.query('select switch_sic_connection($1,$2)',[hash,source]);
});
after(async()=>{await db?.close();});
async function as(id,role='authenticated'){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id??'']);await db.exec(`set role ${role}`);}
async function rpc(sql,args){return (await db.query(sql,args)).rows[0].result;}
async function apply(kind,payload,source=first,eventId=randomUUID()){
 await as(null,'service_role');return rpc('select apply_sic_event($1,$2) result',[hash,JSON.stringify({event_id:eventId,instance_id:source,mode:'production',kind,payload})]);
}
async function unit(){const item={stock_item_id:randomUUID(),product_id:randomUUID(),variant_id:randomUUID(),barcode:`SLB-${900000200001+sequence++}`,name:'Shared unit',quantity:1,expected_quantity:1,revision:1,price:50,cost:20};await apply('unit.upsert',item);return item;}
async function change(item,action='add',request=randomUUID(),tenant=org){await as(user);return rpc('select update_sic_cart($1,$2,$3,$4) result',[tenant,request,action,item.barcode]);}
async function cart(tenant=org){await as(user);return rpc('select read_sic_cart($1) result',[tenant]);}
async function clear(item){await change(item,'remove');}
async function claim(item,source,request){await as(null,'service_role');return rpc('select claim_sic_checkout($1,$2,$3,$4) result',[hash,source,request,JSON.stringify([item])]);}

test('a phone scan is durable, idempotent and visible to both desktop snapshots without changing stock',async()=>{
 const item=await unit(), request=randomUUID();
 const added=await change(item,'add',request);assert.equal(added.state,'saved');
 assert.equal((await change(item,'add',request)).replayed,true);
 assert.equal((await cart()).barcodes.filter(x=>x===item.barcode).length,1);
 await as(null,'service_role');
 for(const source of [first,second]){
  const snapshot=await rpc('select read_sic_snapshot($1,$2) result',[hash,source]);
  assert.deepEqual(snapshot.cart.barcodes,[item.barcode]);
  assert.equal(snapshot.units.find(x=>x.barcode===item.barcode).quantity,1);
 }
 await as(user);assert.equal((await db.query('select count(*)::int n from sic_connections where organization_id=$1 and enabled',[org])).rows[0].n,2);
 await assert.rejects(change(item,'remove',request),/IDEMPOTENCY_CONFLICT/);await clear(item);
});

test('another company cannot read or mutate this store cart and integration snapshots stay tenant-bound',async()=>{
 const item=await unit();await change(item);await as(outsider);
 await assert.rejects(rpc('select read_sic_cart($1) result',[org]),/FORBIDDEN/);
 await assert.rejects(rpc('select update_sic_cart($1,$2,$3,$4) result',[org,randomUUID(),'remove',item.barcode]),/FORBIDDEN/);
 await as(null,'service_role');const snapshot=await rpc('select read_sic_snapshot($1,$2) result',[otherHash,randomUUID()]);
 assert.deepEqual(snapshot.cart.barcodes,[]);assert.equal(snapshot.units.length,0);
 await clear(item);
});

test('desktop add/remove events update the same cart and do not replay a stale scan after removal',async()=>{
 const item=await unit(),eventId=randomUUID();await apply('cart.added',{barcode:item.barcode},first,eventId);
 assert.deepEqual((await cart()).barcodes,[item.barcode]);
 await apply('cart.removed',{barcode:item.barcode},second);
 assert.deepEqual((await cart()).barcodes,[]);
 assert.equal((await apply('cart.added',{barcode:item.barcode},first,eventId)).replayed,true);
 assert.deepEqual((await cart()).barcodes,[]);
});

test('only one desktop claims checkout; another desktop cannot duplicate it or edit the closing cart',async()=>{
 const item=await unit(),request=randomUUID();await change(item);
 assert.equal((await claim(item,second,request)).state,'claimed');
 assert.equal((await claim(item,second,request)).replayed,true);
 await assert.rejects(claim(item,first,randomUUID()),/CHECKOUT_IN_PROGRESS/);
 await assert.rejects(change(item,'remove'),/CHECKOUT_IN_PROGRESS/);
 const payload={sale_id:randomUUID(),items:[item],total:50,payment:'pix',checkout_request_id:request};
 const eventId=randomUUID();const receipt=await apply('sale.confirmed',payload,second,eventId);
 assert.equal(receipt.state,'applied');assert.equal((await apply('sale.confirmed',payload,second,eventId)).replayed,true);
 assert.deepEqual((await cart()).barcodes,[]);
 await as(null,'service_role');
 const snapshot=await rpc('select read_sic_snapshot($1,$2) result',[hash,first]);
 assert.equal(snapshot.units.find(x=>x.barcode===item.barcode).quantity,0);
 await db.exec('reset role');assert.equal((await db.query('select count(*)::int n from sic_checkout_claims where organization_id=$1',[org])).rows[0].n,0);
 await assert.rejects(change(item),/INSUFFICIENT_STOCK/);
});

test('a stale cart cannot be checked out and a confirmed rollback may release its own claim only',async()=>{
 const item=await unit(),other=await unit(),request=randomUUID();await change(item);await change(other);
 await assert.rejects(claim(item,first,request),/CART_CHANGED/);
 await clear(other);await claim(item,first,request);await as(null,'service_role');
 await db.query('select release_sic_checkout($1,$2,$3)',[hash,second,request]);
 await assert.rejects(claim(item,second,randomUUID()),/CHECKOUT_IN_PROGRESS/);
 await as(null,'service_role');await db.query('select release_sic_checkout($1,$2,$3)',[hash,first,request]);
 await clear(item);
});

test('availability updates remove unavailable cart items and remain visible after another desktop reconnects',async()=>{
 const item=await unit();await change(item);
 await apply('stock.adjusted',{unit:{...item,quantity:0,expected_quantity:0,revision:2},reason:'Unavailable',delta:-1},second);
 assert.deepEqual((await cart()).barcodes,[]);
 await as(null,'service_role');const snapshot=await rpc('select read_sic_snapshot($1,$2) result',[hash,first]);
 assert.equal(snapshot.units.find(x=>x.barcode===item.barcode).quantity,0);
});

test('a phone cannot bypass desktop review by queueing the old sale-confirm command',async()=>{
 await as(user);await assert.rejects(rpc('select queue_sic_command($1,$2,$3,$4,$5) result',[org,randomUUID(),first,'cart.confirm','{"lines":[]}']),/DESKTOP_CONFIRMATION_REQUIRED/);
});
