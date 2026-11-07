import { randomBytes, createHash } from 'node:crypto';

const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, ADMIN_ACCESS_TOKEN, ORGANIZATION_ID } = process.env;
if (![SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, ADMIN_ACCESS_TOKEN, ORGANIZATION_ID].every(Boolean)) {
  throw new Error('Configure SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, ADMIN_ACCESS_TOKEN e ORGANIZATION_ID.');
}

const name = process.argv[2] ?? 'Computador da loja';
const maxUses = Number(process.argv[3] ?? 1);
const expiresInHours = Number(process.argv[4] ?? 24);
if (!Number.isInteger(maxUses) || maxUses < 1 || maxUses > 20) throw new Error('O limite de usos deve estar entre 1 e 20.');
if (!Number.isFinite(expiresInHours) || expiresInHours <= 0 || expiresInHours > 24 * 30) throw new Error('A validade deve estar entre 1 hora e 30 dias.');

const groups = randomBytes(6).toString('hex').toUpperCase().match(/.{1,4}/g);
const code = `LB-${groups.join('-')}`;
const hash = createHash('sha256').update(code).digest('hex');
const expiresAt = new Date(Date.now() + expiresInHours * 60 * 60 * 1000).toISOString();
const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/create_desktop_activation`, {
  method: 'POST',
  headers: { apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${ADMIN_ACCESS_TOKEN}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ p_org: ORGANIZATION_ID, p_name: name, p_code_hash: hash, p_max_uses: maxUses, p_expires_at: expiresAt }),
});
if (!response.ok) throw new Error(`Falha ao criar ativação: ${response.status} ${await response.text()}`);
console.log(JSON.stringify({ code, name, max_uses: maxUses, expires_at: expiresAt, id: await response.json(), note: 'O código bruto é exibido somente agora.' }, null, 2));
