import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';

let db;
const org=randomUUID(),otherOrg=randomUUID(),admin=randomUUID(),operator=randomUUID(),source=randomUUID(),hash='c'.repeat(64);
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
 await db.exec(await readFile(new URL('../supabase/migrations/202610220001_core.sql',import.meta.url),'utf8'));
 await db.exec(await readFile(new URL('../supabase/migrations/202610280001_sic_bridge.sql',import.meta.url),'utf8'));
 await db.exec(await readFile(new URL('../supabase/migrations/202610310001_sic_command_bridge.sql',import.meta.url),'utf8'));
 await db.query("insert into auth.users values($1,'admin@test',now()),($2,'operator@test',now())",[admin,operator]);
 await db.query("insert into organizations(id,name) values($1,'SIC test'),($2,'Other')",[org,otherOrg]);
 await db.query("insert into memberships values($1,$2,'admin'),($1,$3,'operator')",[org,admin,operator]);
 await as(admin);await db.query("select add_integration_key($1,'Lab',$2)",[org,hash]);
});
after(async()=>{await db?.close();});
async function as(user,role='authenticated'){await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user??'']);await db.exec(`set role ${role}`);}
const parent=randomUUID(),variant=randomUUID();let number=0;
function unit(extra={}){return {stock_item_id:randomUUID(),product_id:parent,variant_id:variant,barcode:`SLB-${String(900000000001+number++).padStart(12,'0')}`,name:'Camiseta',brand:'Surf',color:'Preta',size:'M',quantity:1,expected_quantity:1,revision:1,price:89.90,cost:40,...extra};}
function event(kind,payload,extra={}){return {event_id:randomUUID(),instance_id:source,mode:'sandbox',kind,payload,...extra};}
async function apply(value){await as(null,'service_role');return (await db.query('select apply_sic_event($1,$2) result',[hash,JSON.stringify(value)])).rows[0].result;}
async function qty(id){await as(admin);return (await db.query('select quantity from stock_items where id=$1',[id])).rows[0].quantity;}

test('connection requires admin registration and explicit sandbox permission',async()=>{
 const value=event('unit.upsert',unit());await assert.rejects(apply(value),/SIC_CONNECTION_NOT_REGISTERED/);
 await as(operator);await assert.rejects(db.query('select register_sic_connection($1,$2,true)',[org,source]),/FORBIDDEN/);
 await as(admin);await db.query('select register_sic_connection($1,$2,false)',[org,source]);
 await assert.rejects(apply(value),/SANDBOX_NOT_ALLOWED/);
 await as(admin);await db.query('select register_sic_connection($1,$2,true)',[org,source]);
});
test('mobile command queue is idempotent and desktop acknowledgement is tenant-bound',async()=>{
 const request=randomUUID(),payload={name:'Bridge product',tracking:'individual',variants:[{color:'Preta',size:'M',quantity:1}],price:89.9,cost:40};
 await as(operator);
 const first=(await db.query('select queue_sic_command($1,$2,$3,$4,$5) result',[org,request,source,'product.create',JSON.stringify(payload)])).rows[0].result;
 assert.equal(first.status,'pending');assert.equal(first.replayed,false);
 const replay=(await db.query('select queue_sic_command($1,$2,$3,$4,$5) result',[org,request,source,'product.create',JSON.stringify(payload)])).rows[0].result;
 assert.equal(replay.command_id,first.command_id);assert.equal(replay.replayed,true);
 await as(null,'service_role');
 await db.query('select ack_sic_command($1,$2,$3,$4,$5,$6)',[org,first.command_id,source,'processing',null,null]);
 const result={product_id:randomUUID()};
 await db.query('select ack_sic_command($1,$2,$3,$4,$5,$6)',[org,first.command_id,source,'completed',JSON.stringify(result),null]);
 await as(operator);
 const row=(await db.query('select status,result from sic_commands where organization_id=$1 and command_id=$2',[org,first.command_id])).rows[0];
 assert.equal(row.status,'completed');assert.deepEqual(row.result,result);
 await assert.rejects(db.query('select queue_sic_command($1,$2,$3,$4,$5)',[org,request,source,'product.create',JSON.stringify({...payload,name:'Changed'})]),/IDEMPOTENCY_CONFLICT/);
});
test('imports one stock item per physical unit; retry never duplicates initial stock',async()=>{
 const item=unit(),value=event('unit.upsert',item);assert.equal((await apply(value)).state,'applied');assert.equal((await apply(value)).replayed,true);assert.equal(await qty(item.stock_item_id),1);
 await assert.rejects(apply({...value,payload:{...item,price:100}}),/IDEMPOTENCY_CONFLICT/);
 await assert.rejects(apply({...value,event_id:randomUUID(),instance_id:randomUUID()}),/SIC_CONNECTION_NOT_REGISTERED/);
});
test('individual edits change cloud variant and preserve unit barcode',async()=>{
 const item=unit();await apply(event('unit.upsert',item));const edited={...item,variant_id:randomUUID(),color:'Azul',revision:2,price:100};
 assert.equal((await apply(event('unit.upsert',edited))).state,'applied');await as(admin);
 const row=(await db.query('select variant_id,barcode from stock_items where id=$1',[item.stock_item_id])).rows[0];assert.equal(row.variant_id,edited.variant_id);assert.equal(row.barcode,item.barcode);
 const older=await apply(event('unit.upsert',item));assert.equal(older.state,'ignored');
});
test('a SIC-bound company cannot bypass the desktop through old mobile RPCs',async()=>{
 await as(operator);
 await assert.rejects(db.query('select create_product($1,$2,$3)',[org,randomUUID(),JSON.stringify({name:'Bypass',tracking:'individual',variants:[{quantity:1}]})]),/LOCAL_CATALOG_REQUIRED/);
 await assert.rejects(db.query('select record_physical_sale($1,$2,$3,$4)',[org,randomUUID(),'[]',null]),/DESKTOP_CONFIRMATION_REQUIRED/);
 await assert.rejects(db.query('select private.cloud_create_product($1,$2,$3)',[org,randomUUID(),'{}']),/permission denied/);
});
test('one local sale becomes one cloud sale and two stock movements, including retries',async()=>{
 const one=unit(),two=unit();await apply(event('unit.upsert',one));await apply(event('unit.upsert',two));
 const value=event('sale.confirmed',{sale_id:randomUUID(),items:[one,two],total:179.80,payment:'pix'});
 const result=await apply(value);assert.equal(result.state,'applied');assert.equal((await apply(value)).cloud_sale_id,result.cloud_sale_id);
 assert.equal(await qty(one.stock_item_id),0);assert.equal(await qty(two.stock_item_id),0);await as(admin);
 assert.equal((await db.query('select count(*)::int n from sales where id=$1',[result.cloud_sale_id])).rows[0].n,1);
 const returned={...one,quantity:1,expected_quantity:1,revision:3};assert.equal((await apply(event('stock.adjusted',{unit:returned,reason:'Retorno',delta:1}))).state,'applied');assert.equal(await qty(one.stock_item_id),1);
});
test('a conflicting cloud sale is preserved; local sync cannot resurrect or sell that unit twice',async()=>{
 const item=unit();await apply(event('unit.upsert',item));await as(null,'service_role');
 await db.query('select record_commerce_sale($1,$2,$3,$4)',[hash,randomUUID(),'test:online-order',JSON.stringify([{barcode:item.barcode,quantity:1}])]);
 const value=event('sale.confirmed',{sale_id:randomUUID(),items:[item],total:89.90,payment:'pix'});
 const result=await apply(value);assert.equal(result.state,'conflict');assert.equal(result.reason,'CLOUD_STOCK_CONFLICT');assert.equal((await apply(value)).state,'conflict');
 assert.equal((await apply(event('unit.upsert',{...item,revision:2}))).state,'conflict');assert.equal(await qty(item.stock_item_id),0);
});
test('sync data and RPC are unavailable to anonymous callers; another tenant sees no links',async()=>{
 await as(null,'anon');await assert.rejects(db.query('select * from sic_unit_links'),/permission denied/);
 await as(operator);await assert.rejects(db.query('select apply_sic_event($1,$2)',[hash,'{}']),/permission denied/);
 await db.exec('reset role');const outsider=randomUUID();await db.query("insert into auth.users values($1,'outsider@test',now())",[outsider]);await db.query("insert into memberships values($1,$2,'admin')",[otherOrg,outsider]);await as(outsider);
 assert.equal((await db.query('select * from sic_unit_links')).rows.length,0);
 const product=(await db.query('select create_product($1,$2,$3) id',[otherOrg,randomUUID(),JSON.stringify({name:'Legacy store',tracking:'individual',variants:[{quantity:1}]})])).rows[0].id;
 const code=(await db.query('select barcode from inventory where product_id=$1',[product])).rows[0].barcode;
 await db.query('select record_physical_sale($1,$2,$3,$4)',[otherOrg,randomUUID(),JSON.stringify([{barcode:code,quantity:1}]),null]);
 assert.equal((await db.query('select quantity from inventory where barcode=$1',[code])).rows[0].quantity,0);
});
