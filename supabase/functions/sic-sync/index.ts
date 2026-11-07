import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { json, sha256 } from "../_shared/http.ts";
import { apiKey } from "../_shared/environment.ts";
import { createR2Storage, R2Error } from "../_shared/r2.ts";
import { decodePhoto, MAX_PHOTO_REQUEST_BYTES, PhotoError, readBoundedBody, validPhotoPath } from "../_shared/product_photos.ts";

// The desktop uses this endpoint for idempotent push and for a full snapshot
// pull. Every enabled SIC installation may register without stealing another.
Deno.serve(async (req) => {
  const token = req.headers.get("Authorization")?.match(/^Bearer (slb_live_[a-f0-9]{64})$/)?.[1];
  if (!token) return json({ error: "UNAUTHORIZED" }, 401);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, apiKey("secret"), { auth: { persistSession: false } });
  const hash = await sha256(token);
  const { data: org, error: authError } = await admin.rpc("integration_organization", { p_hash: hash });
  if (authError || !org) return json({ error: "UNAUTHORIZED" }, 401);
  if (req.method === "GET") {
    const instance = new URL(req.url).searchParams.get("instance_id") ?? "";
    if (!/^[0-9a-f-]{36}$/i.test(instance)) return json({ error: "INVALID_INSTANCE" }, 400);
    const { data, error } = await admin.rpc("read_sic_snapshot", { p_hash: hash, p_instance: instance });
    if (error) return json({ error: "CLOUD_SNAPSHOT_FAILED" }, 500);
    return json(data);
  }
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  try {
    const text = await readBoundedBody(req, MAX_PHOTO_REQUEST_BYTES);
    const event = JSON.parse(text);
    if (!event || typeof event !== "object" || Array.isArray(event)) return json({ error: "INVALID_REQUEST" }, 400);
    if (event.kind === "photo.upload") {
      const photo = decodePhoto(event.content_type, event.data);
      const path = `${org}/${crypto.randomUUID()}.${photo.extension}`;
      const r2 = createR2Storage();
      if (r2) {
        try {
          await r2.upload(path, photo.bytes, photo.contentType);
        } catch (error) {
          if (error instanceof R2Error) return json({ error: "PHOTO_UPLOAD_FAILED" }, 502);
          throw error;
        }
      } else {
        const { error } = await admin.storage.from("product-photos").upload(path, photo.bytes, { contentType: photo.contentType, upsert: false });
        if (error) return json({ error: "PHOTO_UPLOAD_FAILED" }, 502);
      }
      return json({ photo_path: path });
    }
    if (new TextEncoder().encode(text).length > 1_048_576) return json({ error: "REQUEST_TOO_LARGE" }, 413);
    if (event.kind === "photo.url") {
      if (!validPhotoPath(org, event.photo_path)) return json({ error: "INVALID_PHOTO" }, 400);
      const r2 = createR2Storage();
      if (r2) {
        try {
          if (await r2.exists(event.photo_path)) return json({ url: await r2.signedUrl(event.photo_path, 300) });
        } catch (error) {
          if (error instanceof R2Error) return json({ error: "PHOTO_NOT_FOUND" }, 404);
          throw error;
        }
      }
      const { data, error } = await admin.storage.from("product-photos").createSignedUrl(event.photo_path, 300);
      if (error) return json({ error: "PHOTO_NOT_FOUND" }, 404);
      return json({ url: data.signedUrl });
    }
    if (event.kind === "checkout.claim" || event.kind === "checkout.release") {
      const claiming = event.kind === "checkout.claim";
      const params = { p_hash: hash, p_instance: event.instance_id, p_request: event.request_id };
      const { data, error } = claiming
        ? await admin.rpc("claim_sic_checkout", { ...params, p_items: event.items })
        : await admin.rpc("release_sic_checkout", params);
      if (error) {
        const known = ["CHECKOUT_IN_PROGRESS", "CART_CHANGED", "CLOUD_STOCK_CONFLICT", "INVALID_LINES", "SIC_CONNECTION_NOT_REGISTERED", "UNIT_NOT_IMPORTED"];
        return json({ error: known.find((code) => error.message.includes(code)) ?? "CHECKOUT_FAILED" }, 409);
      }
      return json(claiming ? data : { state: "released" });
    }
    const { data, error } = await admin.rpc("apply_sic_event", { p_hash: hash, p_event: event });
    if (error) {
      const known = ["IDEMPOTENCY_CONFLICT", "SANDBOX_NOT_ALLOWED", "SIC_CONNECTION_NOT_REGISTERED", "UNIT_NOT_IMPORTED", "SOURCE_CONFLICT", "INVALID_EVENT", "INVALID_UNIT", "INVALID_SALE", "SALE_NOT_FOUND", "SALE_ALREADY_REVERTED", "SALE_REVERSAL_UNSUPPORTED", "REVERSAL_STOCK_CONFLICT", "CLOUD_STOCK_CONFLICT", "INVALID_PHOTO", "ADMIN_REQUIRED", "CHECKOUT_IN_PROGRESS", "CHECKOUT_CLAIM_REQUIRED", "INSUFFICIENT_STOCK"];
      return json({ error: known.find((code) => error.message.includes(code)) ?? "SYNC_EVENT_FAILED" }, 409);
    }
    return json(data);
  } catch (error) {
    if (error instanceof PhotoError) return json({ error: error.message }, error.message === "REQUEST_TOO_LARGE" || error.message === "PHOTO_TOO_LARGE" ? 413 : 400);
    if (error instanceof R2Error) return json({ error: error.code }, error.status);
    return json({ error: "INVALID_REQUEST" }, 400);
  }
});
