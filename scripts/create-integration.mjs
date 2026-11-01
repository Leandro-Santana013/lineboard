import { randomBytes, createHash } from 'node:crypto';

// Run with a logged-in admin's access token. No service-role key is needed.
const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, ADMIN_ACCESS_TOKEN, ORGANIZATION_ID } = process.env;
if (![SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, ADMIN_ACCESS_TOKEN, ORGANIZATION_ID].every(Boolean)) {
  throw new Error('Configure SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, ADMIN_ACCESS_TOKEN e ORGANIZATION_ID.');
}
const token = `slb_live_${randomBytes(32).toString('hex')}`;
const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/add_integration_key`, {
  method: 'POST', headers: { apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${ADMIN_ACCESS_TOKEN}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ p_org: ORGANIZATION_ID, p_name: process.argv[2] ?? 'E-commerce', p_hash: createHash('sha256').update(token).digest('hex') }),
});
if (!response.ok) throw new Error(`Falha ao criar integração: ${response.status} ${await response.text()}`);
console.log(JSON.stringify({ id: await response.json(), token, note: 'Guarde no servidor do e-commerce; exibido somente agora.' }, null, 2));
