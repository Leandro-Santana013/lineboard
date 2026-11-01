import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { json, sha256 } from "../_shared/http.ts";
import { apiKey } from "../_shared/environment.ts";

// Server-to-server API. The store is derived from its secret, never from the body.
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({});
  if (!["GET", "POST"].includes(req.method)) return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const token = req.headers.get("Authorization")?.match(/^Bearer (slb_live_[a-f0-9]{64})$/)?.[1];
  if (!token) return json({ error: "UNAUTHORIZED" }, 401);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, apiKey("secret"), { auth: { persistSession: false } });
  const hash = await sha256(token);
  const { data: org, error: authError } = await admin.rpc("integration_organization", { p_hash: hash });
  if (authError || !org) return json({ error: "UNAUTHORIZED" }, 401);
  try {
    if (req.method === "GET") {
      const url = new URL(req.url);
      const after = url.searchParams.get("after") ?? "";
      const limit = Number(url.searchParams.get("limit") ?? 100);
      if (!Number.isInteger(limit) || limit < 1 || limit > 500 || (after && !/^SLB-[0-9]{12}$/.test(after))) {
        return json({ error: "INVALID_PAGINATION" }, 400);
      }
      const { data, error } = await admin.from("inventory").select("*").eq("organization_id", org)
        .gt("barcode", after).order("barcode").limit(limit + 1);
      if (error) return json({ error: "INVENTORY_UNAVAILABLE" }, 503);
      const items = data.slice(0, limit);
      return json({ items, next_after: data.length > limit ? items.at(-1)?.barcode : null });
    }
    const key = req.headers.get("Idempotency-Key");
    if (!key || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(key)) {
      return json({ error: "INVALID_IDEMPOTENCY_KEY" }, 400);
    }
    const body = await req.json();
    const { data, error } = await admin.rpc("record_commerce_sale", {
      p_hash: hash, p_key: key, p_reference: body.order_id, p_lines: body.lines,
    });
    if (error) {
      const known = ["INSUFFICIENT_STOCK", "BARCODE_NOT_FOUND", "IDEMPOTENCY_CONFLICT", "REFERENCE_REQUIRED", "INVALID_LINES", "INVALID_SALE", "FORBIDDEN"];
      const code = known.find((c) => error.message.includes(c)) ?? (error.code === "23505" ? "ORDER_ALREADY_RECORDED" : "SALE_FAILED");
      return json({ error: code }, ["INSUFFICIENT_STOCK", "IDEMPOTENCY_CONFLICT", "ORDER_ALREADY_RECORDED"].includes(code) ? 409 : 400);
    }
    return json(data);
  } catch {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
});
