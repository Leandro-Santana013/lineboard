import { test } from 'node:test';
import assert from 'node:assert/strict';
import { R2Error, R2Storage, r2Settings } from '../supabase/functions/_shared/r2.ts';

const values = {
  R2_ACCOUNT_ID: 'account-123',
  R2_ACCESS_KEY_ID: 'access-key',
  R2_SECRET_ACCESS_KEY: 'secret-key',
  R2_BUCKET: 'product-photos',
  R2_REGION: 'auto',
};

test('R2 settings derive the Cloudflare endpoint without exposing secrets', () => {
  const settings = r2Settings((name) => values[name]);
  assert.equal(settings?.endpoint.origin, 'https://account-123.r2.cloudflarestorage.com');
  assert.equal(settings?.bucket, 'product-photos');
  assert.equal(settings?.region, 'auto');
});

test('partial R2 configuration fails closed', () => {
  assert.throws(
    () => r2Settings((name) => ({ R2_BUCKET: 'product-photos' }[name])),
    (error) => error instanceof R2Error && error.code === 'R2_NOT_CONFIGURED',
  );
});

test('R2 signed URLs are private and organization-scoped by object path', async () => {
  const settings = r2Settings((name) => values[name]);
  const storage = new R2Storage(settings);
  const url = new URL(await storage.signedUrl('00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000002.png', 300));
  assert.equal(url.hostname, 'account-123.r2.cloudflarestorage.com');
  assert.equal(url.pathname, '/product-photos/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000002.png');
  assert.equal(url.searchParams.get('X-Amz-Algorithm'), 'AWS4-HMAC-SHA256');
  assert.equal(url.searchParams.get('X-Amz-Expires'), '300');
  assert.equal(url.searchParams.get('X-Amz-SignedHeaders'), 'host');
  assert.match(url.searchParams.get('X-Amz-Signature') ?? '', /^[0-9a-f]{64}$/);
  const head = await storage.signedRequestUrl('00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000002.png', 'HEAD', 60);
  assert.notEqual(new URL(head).searchParams.get('X-Amz-Signature'), url.searchParams.get('X-Amz-Signature'));
});
