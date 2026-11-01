import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { json, sha256 } from "../_shared/http.ts";
import { apiKey } from "../_shared/environment.ts";

// The desktop never receives a service-role key. It acknowledges a command
// with the per-company integration key already used by sic-sync.
Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const token = req.headers.get("Authorization")?.match(/^Bearer (slb_live_[a-f0-9]{64})$/)?.[1];
  if (!token) return json({ error: "UNAUTHORIZED" }, 401);
  try {
    const body = await req.json();
    const commandId = String(body.command_id ?? "");
    const instanceId = String(body.instance_id ?? "");
    const status = String(body.status ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(commandId) || !/^[0-9a-f-]{36}$/i.test(instanceId) || !["processing", "completed", "failed", "conflict"].includes(status)) {
      return json({ error: "INVALID_COMMAND" }, 400);
    }
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, apiKey("secret"), { auth: { persistSession: false } });
    const hash = await sha256(token);
    const { data: org, error: authError } = await admin.rpc("integration_organization", { p_hash: hash });
    if (authError || !org) return json({ error: "UNAUTHORIZED" }, 401);
    const { data, error } = await admin.rpc("ack_sic_command", {
      p_org: org,
      p_command_id: commandId,
      p_instance_id: instanceId,
      p_status: status,
      p_result: body.result ?? null,
      p_error_code: body.error_code ?? null,
    });
    if (error) {
      const known = ["COMMAND_NOT_FOUND", "INVALID_COMMAND_STATUS"];
      return json({ error: known.find((code) => error.message.includes(code)) ?? "COMMAND_ACK_FAILED" }, 409);
    }
    return json(data);
  } catch {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
});
