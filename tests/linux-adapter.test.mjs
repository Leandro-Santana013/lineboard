import test from 'node:test';
import assert from 'node:assert/strict';

import {
  defaultRealtimeUrl,
  heartbeatMessage,
  joinMessage,
  privateAddress,
  snapshotSummary,
  validateConfig,
} from '../linux/lineboard-adapter.mjs';

const token = `slb_live_${'a'.repeat(64)}`;
const baseConfig = {
  syncUrl: 'https://example.supabase.co/functions/v1/sic-sync',
  syncToken: token,
  realtimeUrl: 'wss://example.supabase.co/realtime/v1/websocket',
  realtimeKey: 'public-key',
  instanceId: '11111111-1111-4111-8111-111111111111',
  statePath: '/tmp/lineboard-snapshot.json',
};

test('derives the Supabase Realtime URL from sic-sync', () => {
  assert.equal(defaultRealtimeUrl(baseConfig.syncUrl), 'wss://example.supabase.co/realtime/v1/websocket');
});

test('validates the cloud adapter configuration without logging secrets', () => {
  const value = validateConfig({ ...baseConfig });
  assert.equal(value.instanceId, baseConfig.instanceId);
  assert.throws(() => validateConfig({ ...baseConfig, syncUrl: 'http://example.supabase.co/functions/v1/sic-sync' }), /syncUrl/);
  assert.throws(() => validateConfig({ ...baseConfig, syncToken: 'secret' }), /sync token/);
});

test('joins only the organization shared cart tables', () => {
  const message = joinMessage(baseConfig, '22222222-2222-4222-8222-222222222222');
  assert.equal(message.topic, 'realtime:public:sic_shared_carts');
  assert.equal(message.payload.config.postgres_changes.length, 2);
  assert.equal(message.payload.config.postgres_changes[0].table, 'sic_shared_carts');
  assert.equal(message.payload.config.postgres_changes[0].filter, 'organization_id=eq.22222222-2222-4222-8222-222222222222');
});

test('recognizes private LAN addresses and rejects public addresses', () => {
  assert.equal(privateAddress('127.0.0.1'), true);
  assert.equal(privateAddress('192.168.1.40'), true);
  assert.equal(privateAddress('10.1.2.3'), true);
  assert.equal(privateAddress('8.8.8.8'), false);
});

test('summarizes snapshots without exposing credentials', () => {
  const summary = snapshotSummary({
    state: 'snapshot',
    instance_id: baseConfig.instanceId,
    organization_id: '22222222-2222-4222-8222-222222222222',
    units: [{ barcode: 'SLB-000000000001' }],
    cart: { version: 4, barcodes: ['SLB-000000000001'], items: [{}] },
  }, baseConfig, 'test');
  assert.deepEqual(summary.units, 1);
  assert.deepEqual(summary.cart_version, 4);
  assert.equal(Object.hasOwn(summary, 'syncToken'), false);
});

test('creates Phoenix heartbeat frames', () => {
  const message = heartbeatMessage();
  assert.equal(message.topic, 'phoenix');
  assert.equal(message.event, 'heartbeat');
});
