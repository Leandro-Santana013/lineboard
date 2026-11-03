#!/usr/bin/env node

import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, writeFile, chmod } from 'node:fs/promises';
import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const DEFAULT_SYNC_URL = 'https://isktnezzanqpcrkkqldw.supabase.co/functions/v1/sic-sync';
const DEFAULT_CONFIG = join(homedir(), '.config', 'lineboard', 'adapter.json');
const DEFAULT_STATE = join(homedir(), '.local', 'state', 'lineboard', 'snapshot.json');
const TOKEN_PATTERN = /^slb_live_[a-f0-9]{64}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function expandPath(value) {
  if (!value) return value;
  if (value === '~') return homedir();
  if (value.startsWith('~/')) return join(homedir(), value.slice(2));
  return isAbsolute(value) ? value : join(process.cwd(), value);
}

function configPath(args = {}) {
  return expandPath(args.config || process.env.LINEBOARD_CONFIG || DEFAULT_CONFIG);
}

function statePath(config) {
  return expandPath(config.statePath || process.env.LINEBOARD_STATE || DEFAULT_STATE);
}

async function ensureParent(path) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
}

async function readJson(path, fallback = null) {
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return fallback;
    throw error;
  }
}

async function writePrivateJson(path, value) {
  await ensureParent(path);
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await chmod(temporary, 0o600);
  await rename(temporary, path);
  await chmod(path, 0o600);
}

function parseArgs(argv) {
  const command = argv[0] || 'help';
  const args = { command };
  for (let index = 1; index < argv.length; index += 1) {
    const value = argv[index];
    if (!value.startsWith('--')) continue;
    const name = value.slice(2).replaceAll('-', '_');
    if (name === 'sync_token_stdin' || name === 'realtime_key_stdin' || name === 'no_http' || name === 'help') {
      args[name] = true;
    } else {
      args[name] = argv[++index];
    }
  }
  return args;
}

function defaultRealtimeUrl(syncUrl) {
  const url = new URL(syncUrl);
  return `wss://${url.host}/realtime/v1/websocket`;
}

function validateToken(token, name = 'sync token') {
  if (!TOKEN_PATTERN.test(token || '')) throw new Error(`Invalid ${name}. Expected slb_live_ plus 64 hexadecimal characters.`);
  return token;
}

function validateUuid(value, name) {
  if (!UUID_PATTERN.test(value || '')) throw new Error(`Invalid ${name}.`);
  return value.toLowerCase();
}

function validateConfig(config) {
  if (!config || typeof config !== 'object') throw new Error('Adapter configuration is missing.');
  const sync = new URL(config.syncUrl);
  if (sync.protocol !== 'https:' || !sync.hostname.endsWith('.supabase.co') || sync.pathname !== '/functions/v1/sic-sync' || sync.search || sync.hash) {
    throw new Error('syncUrl must be an HTTPS Supabase /functions/v1/sic-sync URL.');
  }
  validateToken(config.syncToken);
  validateUuid(config.instanceId, 'instance_id');
  if (config.realtimeUrl) {
    const realtime = new URL(config.realtimeUrl);
    if (!['ws:', 'wss:'].includes(realtime.protocol) || !realtime.pathname.endsWith('/realtime/v1/websocket')) {
      throw new Error('realtimeUrl must point to /realtime/v1/websocket.');
    }
  }
  if (!config.statePath) config.statePath = DEFAULT_STATE;
  return config;
}

async function loadConfig(args = {}) {
  const path = configPath(args);
  const config = await readJson(path);
  if (!config) throw new Error(`Configuration not found at ${path}. Run configure first.`);
  config._path = path;
  return validateConfig(config);
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8').trim();
}

async function readSecret(args, flag, environment) {
  if (args[flag]) return (await readStdin()).split(/\r?\n/)[0].trim();
  return (process.env[environment] || '').trim();
}

async function configure(args) {
  const syncUrl = args.sync_url || process.env.LINEBOARD_SYNC_URL || DEFAULT_SYNC_URL;
  const syncToken = validateToken(await readSecret(args, 'sync_token_stdin', 'LINEBOARD_SYNC_TOKEN'));
  const realtimeKey = (await readSecret(args, 'realtime_key_stdin', 'LINEBOARD_REALTIME_KEY')) || null;
  const instanceId = validateUuid(args.instance_id || process.env.LINEBOARD_INSTANCE_ID || randomUUID(), 'instance_id');
  const realtimeUrl = args.realtime_url || process.env.LINEBOARD_REALTIME_URL || defaultRealtimeUrl(syncUrl);
  const config = validateConfig({
    version: 1,
    syncUrl,
    syncToken,
    realtimeUrl,
    realtimeKey,
    instanceId,
    organizationId: args.organization_id || process.env.LINEBOARD_ORGANIZATION_ID || null,
    statePath: args.state_path || process.env.LINEBOARD_STATE || DEFAULT_STATE,
    mode: args.mode || process.env.LINEBOARD_MODE || 'production',
    listenHost: args.host || process.env.LINEBOARD_ADAPTER_HOST || '127.0.0.1',
    listenPort: Number(args.port || process.env.LINEBOARD_ADAPTER_PORT || 47832),
  });
  const path = configPath(args);
  delete config._path;
  await writePrivateJson(path, config);
  console.log(JSON.stringify({ configured: true, config: path, state: expandPath(config.statePath), instance_id: config.instanceId, realtime_configured: Boolean(config.realtimeKey) }));
}

async function requestJson(url, options = {}) {
  const response = await fetch(url, { redirect: 'error', ...options, headers: { accept: 'application/json', ...(options.headers || {}) } });
  const text = await response.text();
  let value;
  try {
    value = text ? JSON.parse(text) : null;
  } catch {
    throw new Error(`Invalid JSON response (${response.status}).`);
  }
  if (!response.ok) throw new Error(value?.error || `HTTP_${response.status}`);
  return value;
}

function authHeaders(config) {
  return { authorization: `Bearer ${config.syncToken}` };
}

function snapshotSummary(snapshot, config, reason) {
  return {
    state: snapshot?.state || 'snapshot',
    reason,
    instance_id: snapshot?.instance_id || config.instanceId,
    organization_id: snapshot?.organization_id || config.organizationId || null,
    units: Array.isArray(snapshot?.units) ? snapshot.units.length : 0,
    cart_version: snapshot?.cart?.version ?? 0,
    cart_items: Array.isArray(snapshot?.cart?.barcodes) ? snapshot.cart.barcodes.length : 0,
    received_at: new Date().toISOString(),
  };
}

async function syncNow(config, reason = 'manual') {
  const url = new URL(config.syncUrl);
  url.searchParams.set('instance_id', config.instanceId);
  const snapshot = await requestJson(url, { headers: authHeaders(config) });
  if (snapshot?.instance_id?.toLowerCase() !== config.instanceId.toLowerCase()) throw new Error('Snapshot belongs to another instance.');
  if (!config.organizationId && snapshot.organization_id) {
    config.organizationId = snapshot.organization_id;
    const persisted = { ...config };
    delete persisted._path;
    await writePrivateJson(config._path, persisted);
  }
  const saved = { ...snapshot, adapter: snapshotSummary(snapshot, config, reason) };
  await writePrivateJson(statePath(config), saved);
  return saved.adapter;
}

async function status(args) {
  const config = await loadConfig(args);
  const snapshot = await readJson(statePath(config));
  console.log(JSON.stringify({
    configured: true,
    instance_id: config.instanceId,
    organization_id: config.organizationId || snapshot?.organization_id || null,
    realtime_configured: Boolean(config.realtimeKey),
    state_path: statePath(config),
    snapshot: snapshot ? snapshotSummary(snapshot, config, 'stored') : null,
  }, null, 2));
}

async function resolveOrganization(config) {
  if (config.organizationId) return config.organizationId;
  if (!config.realtimeKey) return null;
  const base = new URL(config.syncUrl);
  const url = new URL('/rest/v1/sic_connections', base.origin);
  url.searchParams.set('select', 'organization_id');
  url.searchParams.set('instance_id', `eq.${config.instanceId}`);
  url.searchParams.set('enabled', 'eq.true');
  url.searchParams.set('limit', '1');
  const rows = await requestJson(url, { headers: { apikey: config.realtimeKey, authorization: `Bearer ${config.realtimeKey}` } });
  const organizationId = rows?.[0]?.organization_id || null;
  if (organizationId) {
    config.organizationId = organizationId;
    const persisted = { ...config };
    delete persisted._path;
    await writePrivateJson(config._path, persisted);
  }
  return organizationId;
}

function joinMessage(config, organizationId) {
  const topic = 'realtime:public:sic_shared_carts';
  return {
    topic,
    event: 'phx_join',
    payload: {
      config: {
        broadcast: { ack: false, self: false },
        presence: { key: '' },
        postgres_changes: [
          { event: 'INSERT', schema: 'public', table: 'sic_shared_carts', filter: `organization_id=eq.${organizationId}` },
          { event: 'UPDATE', schema: 'public', table: 'sic_shared_carts', filter: `organization_id=eq.${organizationId}` },
        ],
      },
      access_token: config.realtimeKey,
    },
    ref: '1',
  };
}

function heartbeatMessage() {
  return { topic: 'phoenix', event: 'heartbeat', payload: {}, ref: randomUUID() };
}

function privateAddress(address) {
  if (address === '127.0.0.1' || address === '::1' || address === 'localhost') return true;
  const octets = String(address).split('.').map(Number);
  return octets.length === 4 && octets.every((part) => Number.isInteger(part) && part >= 0 && part <= 255) && (octets[0] === 10 || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) || (octets[0] === 192 && octets[1] === 168));
}

function sendJson(response, statusCode, value, instanceId = null) {
  const body = JSON.stringify(value);
  response.statusCode = statusCode;
  response.setHeader('content-type', 'application/json; charset=utf-8');
  response.setHeader('cache-control', 'no-store');
  if (instanceId) response.setHeader('x-lineboard-instance', instanceId);
  response.end(body);
}

async function bodyJson(request, maxBytes = 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBytes) throw new Error('REQUEST_TOO_LARGE');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
}

function authorizedLocalRequest(request, config) {
  const origin = request.headers.origin;
  if (origin) return false;
  const remote = request.socket.remoteAddress?.replace(/^::ffff:/, '') || '';
  if (!privateAddress(remote)) return false;
  return request.headers.authorization === `Bearer ${config.syncToken}`;
}

async function startHttp(config) {
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, `http://${request.headers.host || 'localhost'}`);
      if (!privateAddress(request.socket.remoteAddress?.replace(/^::ffff:/, '') || '')) return sendJson(response, 403, { error: 'REQUEST_ORIGIN_REFUSED' });
      const snapshot = await readJson(statePath(config), null);
      if (url.pathname === '/api/health' && request.method === 'GET') {
        return sendJson(response, 200, { mode: 'linux_cloud_adapter', instance_id: config.instanceId, cloud_configured: true, local_sic: false, sale_supported: false, snapshot: snapshot ? snapshotSummary(snapshot, config, 'stored') : null }, config.instanceId);
      }
      if (!authorizedLocalRequest(request, config)) return sendJson(response, 401, { error: 'UNAUTHORIZED' }, config.instanceId);
      if (url.pathname === '/api/catalog' && request.method === 'GET') return sendJson(response, 200, { items: snapshot?.units || [] }, config.instanceId);
      if (url.pathname === '/api/cart' && request.method === 'GET') return sendJson(response, 200, snapshot?.cart || { version: 0, barcodes: [], items: [] }, config.instanceId);
      return sendJson(response, 404, { error: 'NOT_FOUND' }, config.instanceId);
    } catch (error) {
      return sendJson(response, error.message === 'REQUEST_TOO_LARGE' ? 413 : 500, { error: error.message || 'LINUX_ADAPTER_FAILED' }, config.instanceId);
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(config.listenPort, config.listenHost, resolve);
  });
  return server;
}

async function watchRealtime(config, onEvent) {
  if (!config.realtimeKey) throw new Error('Realtime is not configured. Set LINEBOARD_REALTIME_KEY before run.');
  const organizationId = await resolveOrganization(config);
  if (!organizationId) throw new Error('Could not resolve organization_id for this instance.');
  if (typeof WebSocket !== 'function') throw new Error('Node.js WebSocket client is unavailable. Use Node.js 22 or newer.');
  let stopped = false;
  let socket;
  let reconnectTimer;
  let heartbeatTimer;
  const connect = () => {
    if (stopped) return;
    const url = new URL(config.realtimeUrl);
    url.searchParams.set('apikey', config.realtimeKey);
    url.searchParams.set('vsn', '1.0.0');
    socket = new WebSocket(url);
    socket.addEventListener('open', () => {
      socket.send(JSON.stringify(joinMessage(config, organizationId)));
      clearInterval(heartbeatTimer);
      heartbeatTimer = setInterval(() => {
        if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(heartbeatMessage()));
      }, 15000);
      void onEvent('reconnect');
    });
    socket.addEventListener('message', (message) => {
      try {
        const value = JSON.parse(String(message.data));
        const data = value?.payload?.data;
        if (value?.event === 'postgres_changes' && data?.table === 'sic_shared_carts') void onEvent('shared_cart_changed');
      } catch {
        // Ignore malformed frames; the next reconnect will recover the snapshot.
      }
    });
    const reconnect = () => {
      clearInterval(heartbeatTimer);
      if (!stopped && !reconnectTimer) reconnectTimer = setTimeout(() => { reconnectTimer = null; connect(); }, 5000);
    };
    socket.addEventListener('close', reconnect);
    socket.addEventListener('error', reconnect);
  };
  connect();
  return () => {
    stopped = true;
    clearInterval(heartbeatTimer);
    clearTimeout(reconnectTimer);
    socket?.close();
  };
}

async function run(args) {
  const config = await loadConfig(args);
  let inFlight = false;
  let pending = false;
  const requestSync = async (reason) => {
    if (inFlight) { pending = true; return; }
    inFlight = true;
    try {
      const result = await syncNow(config, reason);
      console.log(JSON.stringify(result));
    } catch (error) {
      console.error(`sync failed: ${error.message}`);
    } finally {
      inFlight = false;
      if (pending) { pending = false; void requestSync('coalesced_event'); }
    }
  };
  await requestSync('startup');
  const server = args.no_http ? null : await startHttp({ ...config, listenHost: args.host || config.listenHost, listenPort: Number(args.port || config.listenPort) });
  if (server) console.log(JSON.stringify({ http: `http://${config.listenHost}:${config.listenPort}`, local_api: 'read_only_catalog_and_cart' }));
  const stopRealtime = await watchRealtime(config, requestSync);
  const stop = () => { stopRealtime(); server?.close(); process.exit(0); };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  await new Promise(() => {});
}

async function main(args) {
  if (args.command === 'configure') return configure(args);
  if (args.command === 'sync-now') {
    const config = await loadConfig(args);
    console.log(JSON.stringify(await syncNow(config, 'manual'), null, 2));
    return;
  }
  if (args.command === 'status') return status(args);
  if (args.command === 'run') return run(args);
  console.log(`Lineboard Linux adapter\n\nCommands:\n  configure  Save cloud credentials and instance identity\n  sync-now   Pull one authenticated snapshot\n  status     Show non-secret local status\n  run        Pull, serve read-only LAN state, and listen to Realtime\n\nSecrets are read from LINEBOARD_SYNC_TOKEN / LINEBOARD_REALTIME_KEY or stdin flags; they are never printed.`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(parseArgs(process.argv.slice(2))).catch((error) => { console.error(error.message); process.exitCode = 1; });
}

export { defaultRealtimeUrl, heartbeatMessage, joinMessage, privateAddress, snapshotSummary, validateConfig };
