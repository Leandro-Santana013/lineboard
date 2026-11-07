import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

let db;
const org = randomUUID();
const admin = randomUUID();
const otherOrg = randomUUID();
const otherAdmin = randomUUID();
const activationHash = createHash('sha256').update('LB-TEST-0001-0002').digest('hex');
const tokenHash = 'a'.repeat(64);
const instance = randomUUID();

before(async () => {
  db = new PGlite();
  await db.exec(`
    create role anon;
    create role authenticated;
    create role service_role bypassrls;
    create schema auth;
    create schema storage;
    grant usage on schema public,auth,storage to anon,authenticated,service_role;
    create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text);
    alter table storage.objects enable row level security;
    grant select,insert,delete on storage.objects to authenticated;
    create function storage.foldername(text) returns text[] language sql immutable as $$select string_to_array($1,'/')$$;
  `);
  await db.exec(await readFile(new URL('../supabase/migrations/202610220001_core.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('../supabase/migrations/202610280001_sic_bridge.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('../supabase/migrations/202611070001_desktop_activation.sql', import.meta.url), 'utf8'));
  await db.query('insert into auth.users values($1,$2,now()),($3,$4,now())', [admin, 'admin@test', otherAdmin, 'other@test']);
  await db.query('insert into organizations(id,name) values($1,$2),($3,$4)', [org, 'Activation test', otherOrg, 'Other']);
  await db.query('insert into memberships values($1,$2,$3),($4,$5,$6)', [org, admin, 'admin', otherOrg, otherAdmin, 'admin']);
});

after(async () => { await db?.close(); });

async function as(user, role = 'authenticated') {
  await db.exec('reset role');
  await db.query('select set_config($1,$2,false)', ['request.jwt.claim.sub', user ?? '']);
  await db.exec(`set role ${role}`);
}

test('admin creates an activation and service role consumes it once', async () => {
  await as(admin);
  const created = (await db.query(
    `select create_desktop_activation($1,$2,$3,$4,now()+interval '1 hour') id`,
    [org, 'Demo desktop', activationHash, 1],
  )).rows[0].id;
  assert.ok(created);

  await as(null, 'service_role');
  const consumed = (await db.query(
    'select consume_desktop_activation($1,$2,$3,$4) result',
    [activationHash, instance, 'Caja principal', tokenHash],
  )).rows[0].result;
  await db.exec('reset role');
  assert.equal(consumed.organization_id, org);
  assert.ok(consumed.integration_key_id);
  assert.equal((await db.query('select integration_organization($1) organization_id', [tokenHash])).rows[0].organization_id, org);
  assert.equal((await db.query('select device_name from desktop_installations where instance_id=$1', [instance])).rows[0].device_name, 'Caja principal');
  await assert.rejects(db.query('select consume_desktop_activation($1,$2,$3,$4)', [activationHash, randomUUID(), 'Outro', 'b'.repeat(64)]), /ACTIVATION_LIMIT_REACHED/);
});

test('non-admin cannot issue an activation for another store', async () => {
  await as(otherAdmin);
  await assert.rejects(db.query(
    `select create_desktop_activation($1,$2,$3,1,now()+interval '1 hour')`,
    [org, 'forbidden', 'c'.repeat(64)],
  ), /FORBIDDEN/);
});

test('expired and revoked activations cannot be consumed', async () => {
  const expired = createHash('sha256').update('LB-TEST-0003-0004').digest('hex');
  const revoked = createHash('sha256').update('LB-TEST-0005-0006').digest('hex');
  await as(admin);
  const expiredId = (await db.query(`select create_desktop_activation($1,'Expired',$2,1,now()+interval '1 hour') id`, [org, expired])).rows[0].id;
  await db.exec('reset role');
  await db.query('update desktop_activation_codes set expires_at=now()-interval \'1 minute\' where id=$1', [expiredId]);
  const revokedId = (await db.query(`select create_desktop_activation($1,'Revoked',$2,1,now()+interval '1 hour') id`, [org, revoked])).rows[0].id;
  await db.query('update desktop_activation_codes set revoked_at=now() where id=$1', [revokedId]);
  await as(null, 'service_role');
  await assert.rejects(db.query('select consume_desktop_activation($1,$2,$3,$4)', [expired, randomUUID(), 'Expired', 'd'.repeat(64)]), /ACTIVATION_EXPIRED/);
  await assert.rejects(db.query('select consume_desktop_activation($1,$2,$3,$4)', [revoked, randomUUID(), 'Revoked', 'e'.repeat(64)]), /ACTIVATION_REVOKED/);
});
