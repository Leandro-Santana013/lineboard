import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { json } from '../supabase/functions/_shared/http.ts';

const source = stripTypeScriptTypes((await readFile(new URL('../supabase/functions/sic-sync/index.ts', import.meta.url), 'utf8')).replace(/^import .*;$/gm, ''));
const org = '00000000-0000-4000-8000-000000000001';
const instance = '00000000-0000-4000-8000-000000000002';
const token = `slb_live_${'a'.repeat(64)}`;

function setup({ authenticated = true, version = 12, failure = false } = {}) {
  let handler;
  const queries = [];
  const admin = {
    async rpc(name, params) {
      queries.push({ name, params });
      assert.equal(name, 'integration_organization', 'version checks must not download the full snapshot');
      return { data: authenticated ? org : null, error: null };
    },
    from(table) {
      const query = { table };
      queries.push(query);
      return {
        select(columns) { query.columns = columns; return this; },
        eq(column, value) { query.column = column; query.value = value; return this; },
        async maybeSingle() { return { data: version === null ? null : { version }, error: failure ? { message: 'offline' } : null }; },
      };
    },
  };
  new Function('Deno', 'createClient', 'apiKey', 'json', 'sha256', source)(
    { serve(fn) { handler = fn; }, env: { get() { return 'https://test.supabase.co'; } } },
    () => admin, () => 'server-only', json, async () => 'token-hash',
  );
  const request = (headers = { Authorization: `Bearer ${token}` }, suffix = '') => handler(new Request(
    `https://test.supabase.co/functions/v1/sic-sync?kind=cart-version&instance_id=${instance}${suffix}`, { headers },
  ));
  return { request, queries };
}

test('version check returns a tiny uncached marker scoped to the authenticated integration', async () => {
  const { request, queries } = setup();
  const response = await request(undefined, '&organization_id=another-store');
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { state: 'cart_version', organization_id: org, instance_id: instance, version: '12' });
  assert.deepEqual(queries[1], { table: 'sic_shared_carts', columns: 'version', column: 'organization_id', value: org });
  assert.equal(queries.length, 2);
});

test('missing or revoked credentials cannot inspect the cart version', async () => {
  const missing = setup();
  assert.equal((await missing.request({})).status, 401);
  assert.equal(missing.queries.length, 0);
  const revoked = setup({ authenticated: false });
  assert.equal((await revoked.request()).status, 401);
  assert.equal(revoked.queries.length, 1);
});

test('empty carts have version zero; database failures do not look like successful reads', async () => {
  assert.equal((await (await setup({ version: null }).request()).json()).version, '0');
  const response = await setup({ failure: true }).request();
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'CART_VERSION_FAILED' });
});
