import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { json, sha256 } from "../_shared/http.ts";
import { apiKey } from "../_shared/environment.ts";

const UUID = /^[0-9a-f-]{36}$/i;
const CODE = /^LB-[A-Z0-9]{4}(?:-[A-Z0-9]{4}){2}$/;

function randomHex(bytes: number) {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return Array.from(value, (part) => part.toString(16).padStart(2, "0")).join("");
}

function errorCode(error: unknown) {
  const value = error as { message?: unknown; code?: unknown; details?: unknown; hint?: unknown };
  const message = [value?.message, value?.code, value?.details, value?.hint]
    .filter((part) => part !== undefined && part !== null)
    .map((part) => String(part))
    .join(" ");
  const known = ["ACTIVATION_INVALID", "ACTIVATION_REVOKED", "ACTIVATION_EXPIRED", "ACTIVATION_LIMIT_REACHED", "ACTIVATION_INSTANCE_USED"];
  return known.find((code) => message.includes(code)) ?? "ACTIVATION_FAILED";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({});
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  try {
    const body = await req.json();
    const code = typeof body?.code === "string" ? body.code.trim().toUpperCase().replace(/\s+/g, "") : "";
    const instanceId = typeof body?.instance_id === "string" ? body.instance_id.trim() : "";
    const deviceName = typeof body?.device_name === "string" && body.device_name.trim() ? body.device_name.trim().slice(0, 120) : "Lineboard desktop";
    if (!CODE.test(code) || !UUID.test(instanceId)) return json({ error: "ACTIVATION_INVALID" }, 400);

    const token = `slb_live_${randomHex(32)}`;
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, apiKey("secret"), { auth: { persistSession: false } });
    const { data, error } = await admin.rpc("consume_desktop_activation", {
      p_code_hash: await sha256(code),
      p_instance: instanceId,
      p_device_name: deviceName,
      p_token_hash: await sha256(token),
    });
    if (error) return json({ error: errorCode(error) }, errorCode(error) === "ACTIVATION_FAILED" ? 500 : 409);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const host = new URL(supabaseUrl).host;
    const realtimeKey = Deno.env.get("LINEBOARD_REALTIME_KEY") ?? "";
    const config: Record<string, string> = {
      SUPABASE_URL: supabaseUrl,
      LINEBOARD_SYNC_URL: `${supabaseUrl}/functions/v1/sic-sync`,
      LINEBOARD_SYNC_TOKEN: token,
      LINEBOARD_REALTIME_URL: `wss://${host}/realtime/v1/websocket`,
      LINEBOARD_REALTIME_ACK_URL: `${supabaseUrl}/functions/v1/sic-command-ack`,
    };
    if (realtimeKey) config.LINEBOARD_REALTIME_KEY = realtimeKey;
    return json({ activated: true, organization_id: data.organization_id, instance_id: instanceId, config });
  } catch {
    return json({ error: "ACTIVATION_INVALID" }, 400);
  }
});
