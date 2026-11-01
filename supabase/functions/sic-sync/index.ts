import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { json, sha256 } from "../_shared/http.ts";
import { apiKey } from "../_shared/environment.ts";

// Desktop-to-cloud only. Pairing credentials from the LAN API never authorize this endpoint.
Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const token = req.headers.get("Authorization")?.match(/^Bearer (slb_live_[a-f0-9]{64})$/)?.[1];
  if (!token) return json({ error: "UNAUTHORIZED" }, 401);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, apiKey("secret"), { auth: { persistSession: false } });
  const hash = await sha256(token);
  const { data: org, error: authError } = await admin.rpc("integration_organization", { p_hash: hash });
  if (authError || !org) return json({ error: "UNAUTHORIZED" }, 401);
  try {
    const text = await req.text();
    if (text.length > 1_048_576) return json({ error: "REQUEST_TOO_LARGE" }, 413);
    const event = JSON.parse(text);
    const { data, error } = await admin.rpc("apply_sic_event", { p_hash: hash, p_event: event });
    if (error) {
      const known = ["IDEMPOTENCY_CONFLICT", "SANDBOX_NOT_ALLOWED", "SIC_CONNECTION_NOT_REGISTERED", "UNIT_NOT_IMPORTED", "SOURCE_CONFLICT", "INVALID_EVENT", "INVALID_UNIT", "INVALID_SALE", "ADMIN_REQUIRED"];
      return json({ error: known.find((code) => error.message.includes(code)) ?? "SYNC_EVENT_FAILED" }, 409);
    }
    return json(data);
  } catch {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
});
