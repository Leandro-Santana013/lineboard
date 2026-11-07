import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';

let db;
const org=randomUUID(),other=randomUUID(),user=randomUUID(),outsider=randomUUID(),source=randomUUID(),hash='f'.repeat(64);
const photo=`${org}/${randomUUID()}.png`,replacement=`${org}/${randomUUID()}.jpg`,foreign=`${other}/${randomUUID()}.png`;
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
 alter table storage.objects enable row level security;grant select,insert,delete on storage.objects to authenticated;
 create function storage.foldername(text) returns text[] language sql immutable as $$select string_to_array($1,'/')$$;`);
 const folder=new URL('../supabase/migrations/',import.meta.url);
 for(const file of (await readdir(folder)).filter(x=>x.endsWith('.sql')).sort())await db.exec(await readFile(new URL(file,folder),'utf8'));
 await db.query("insert into auth.users values($1,'photos@test',now()),($2,'other@test',now())",[user,outsider]);
 await db.query("insert into organizations(id,name) values($1,'Photos'),($2,'Other')",[org,other]);
 await db.query("insert into memberships values($1,$2,'admin'),($3,$4,'operator')",[org,user,other,outsider]);
 for(const name of [photo,replacement,foreign])await db.query("insert into storage.objects(bucket_id,name) values('product-photos',$1)",[name]);
 await as(user);await db.query("select add_integration_key($1,'Photos',$2)",[org,hash]);
 await as(null,'service_role');await db.query('select switch_sic_connection($1,$2)',[hash,source]);
});
after(async()=>{await db?.close();});
async function as(id,role='authenticated'){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id??'']);await db.exec(`set role ${role}`);}
function unit(extra={}){return {stock_item_id:randomUUID(),product_id:randomUUID(),variant_id:randomUUID(),barcode:`SLB-${900000400001+sequence++}`,name:'Photo product',quantity:1,expected_quantity:1,revision:1,price:30,cost:10,photo_path:photo,...extra};}
function event(item){return {event_id:randomUUID(),instance_id:source,mode:'production',kind:'unit.upsert',payload:item};}
async function apply(value){await as(null,'service_role');return (await db.query('select apply_sic_event($1,$2) result',[hash,JSON.stringify(value)])).rows[0].result;}
async function edit(product,fields){await as(user);await db.query('select update_product($1,$2,$3)',[org,product,JSON.stringify(fields)]);}
async function snapshot(){await as(null,'service_role');return (await db.query('select read_sic_snapshot($1,$2) result',[hash,source])).rows[0].result;}

test('desktop photo is projected to the private mobile catalog for every variant',async()=>{
 const first=unit(),second=unit({product_id:first.product_id,size:'G'});
 await apply(event(first));await apply(event(second));await as(user);
 const rows=(await db.query('select photo_path,barcode from mobile_catalog where product_id=$1',[first.product_id])).rows;
 assert.equal(rows.length,2);assert.ok(rows.every(x=>x.photo_path===photo));
});

test('mobile product creation stores and projects all tenant-scoped photos',async()=>{
 const request=randomUUID();
 const product={name:'Mobile gallery',tracking:'individual',photo_path:photo,photo_paths:[photo,replacement],
  variants:[{color:'Preta',size:'M',quantity:1}]};
 await as(user);
 const created=(await db.query('select create_product($1,$2,$3) id',[org,request,JSON.stringify(product)])).rows[0].id;
 const stored=(await db.query('select photo_path,photo_paths from products where id=$1',[created])).rows[0];
 assert.equal(stored.photo_path,photo);assert.deepEqual(stored.photo_paths,[photo,replacement]);
 const catalog=(await db.query('select photo_path,photo_paths from mobile_catalog where product_id=$1',[created])).rows[0];
 assert.equal(catalog.photo_path,photo);assert.deepEqual(catalog.photo_paths,[photo,replacement]);
 const replay=await db.query('select create_product($1,$2,$3) id',[org,request,JSON.stringify(product)]);
 assert.equal(replay.rows[0].id,created);
});

test('replacement and removal reach all desktop snapshots without changing stock; retries and omitted fields preserve photo',async()=>{
 const first=unit(),second=unit({product_id:first.product_id,size:'G'});const original=event(first);
 await apply(original);await apply(event(second));
 await edit(first.product_id,{photo_path:replacement});
 let units=(await snapshot()).units.filter(x=>x.product_id===first.product_id);
 assert.ok(units.every(x=>x.photo_path===replacement&&x.revision===2&&x.quantity===1));
 await edit(first.product_id,{photo_path:replacement});await edit(first.product_id,{name:'Renamed'});
 units=(await snapshot()).units.filter(x=>x.product_id===first.product_id);
 assert.ok(units.every(x=>x.photo_path===replacement&&x.revision===2));
 assert.equal((await apply(original)).replayed,true);
 const stale=await apply(event({...first,price:31}));assert.equal(stale.state,'ignored');
 await as(user);assert.equal((await db.query('select photo_path from products where id=$1',[first.product_id])).rows[0].photo_path,replacement);
 await edit(first.product_id,{photo_path:null});
 units=(await snapshot()).units.filter(x=>x.product_id===first.product_id);
 assert.ok(units.every(x=>x.photo_path===''&&x.revision===3&&x.quantity===1));
 await as(user);assert.equal((await db.query('select photo_path from products where id=$1',[first.product_id])).rows[0].photo_path,null);
 assert.equal((await db.query('select count(*)::int n from stock_movements where stock_item_id in ($1,$2)',[first.stock_item_id,second.stock_item_id])).rows[0].n,2);
});

test('foreign, URL and malformed photos roll back while external R2 references are accepted',async()=>{
 for(const path of [foreign,'https://example.com/photo.png',`${org}/../other.png`]){
  const item=unit({photo_path:path});await assert.rejects(apply(event(item)),/INVALID_PHOTO/);
  await as(user);assert.equal((await db.query('select count(*)::int n from stock_items where id=$1',[item.stock_item_id])).rows[0].n,0);
 }
 const external=`${org}/${randomUUID()}.png`,externalItem=unit({photo_path:external});
 await apply(event(externalItem));
 await as(user);assert.equal((await db.query('select photo_path from products where id=$1',[externalItem.product_id])).rows[0].photo_path,external);
 const item=unit();await apply(event(item));
 await assert.rejects(edit(item.product_id,{photo_path:foreign}),/INVALID_PHOTO/);
 await as(outsider);await assert.rejects(db.query('select update_product($1,$2,$3)',[org,item.product_id,JSON.stringify({photo_path:null})]),/FORBIDDEN/);
});

test('late initial units cannot undo a photo changed on the phone during initial sync',async()=>{
 const first=unit(),second=unit({product_id:first.product_id,size:'G'});
 await apply(event(first));await edit(first.product_id,{photo_path:replacement});
 const delayed=event(second);await apply(delayed);await apply(delayed);
 const units=(await snapshot()).units.filter(x=>x.product_id===first.product_id);
 assert.ok(units.every(x=>x.photo_path===replacement&&x.revision===2));
 await as(user);assert.equal((await db.query('select photo_path from products where id=$1',[first.product_id])).rows[0].photo_path,replacement);
});

test('editing a photo cannot invalidate an active checkout claim',async()=>{
 const item=unit();await apply(event(item));await as(user);
 await db.query('select update_sic_cart($1,$2,$3,$4)',[org,randomUUID(),'add',item.barcode]);
 const request=randomUUID();await as(null,'service_role');
 await db.query('select claim_sic_checkout($1,$2,$3,$4)',[hash,source,request,JSON.stringify([item])]);
 await assert.rejects(edit(item.product_id,{photo_path:replacement}),/CHECKOUT_IN_PROGRESS/);
 await as(null,'service_role');await db.query('select release_sic_checkout($1,$2,$3)',[hash,source,request]);
});

test('reversing a SIC sale restores cloud stock, link revision and is idempotent',async()=>{
 const item=unit();await apply(event(item));
 const saleId=randomUUID();
 const sale={event_id:randomUUID(),instance_id:source,mode:'production',kind:'sale.confirmed',payload:{sale_id:saleId,items:[item],total:30,payment:'pix'}};
 assert.equal((await apply(sale)).state,'applied');
 const reversal={event_id:randomUUID(),instance_id:source,mode:'production',kind:'sale.reversed',payload:{sale_id:saleId}};
 const first=await apply(reversal);assert.equal(first.state,'applied');assert.equal(first.reversed,true);
 const replay=await apply(reversal);assert.equal(replay.replayed,true);
 await as(user);
 assert.equal((await db.query('select quantity from stock_items where id=$1',[item.stock_item_id])).rows[0].quantity,1);
 assert.equal((await db.query("select count(*)::int n from stock_movements where stock_item_id=$1 and reason='sale_reversal'",[item.stock_item_id])).rows[0].n,1);
 const link=(await db.query('select last_quantity,last_revision,snapshot->>\'quantity\' quantity from sic_unit_links where stock_item_id=$1',[item.stock_item_id])).rows[0];
 assert.equal(link.last_quantity,1);assert.equal(link.last_revision,3);assert.equal(link.quantity,'1');
});
