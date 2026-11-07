import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { apiKey } from "../_shared/environment.ts";
import { json } from "../_shared/http.ts";
import { createR2Storage, R2Error } from "../_shared/r2.ts";
import {
  decodePhoto,
  MAX_PHOTO_REQUEST_BYTES,
  PhotoError,
  readBoundedBody,
  validPhotoPath,
} from "../_shared/product_photos.ts";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function authorization(req: Request): string {
  const value = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+$/i.test(value)) throw new PhotoError("UNAUTHORIZED");
  return value;
}

async function memberClient(req: Request) {
  const url = Deno.env.get("SUPABASE_URL")!;
  const client = createClient(url, apiKey("publishable"), {
    global: { headers: { Authorization: authorization(req) } },
    auth: { persistSession: false },
  });
  const { data: identity, error: authError } = await client.auth.getUser();
  if (authError || !identity.user) throw new PhotoError("UNAUTHORIZED");
  return client;
}

async function isMember(client: any, organization: string): Promise<boolean> {
  const { data, error } = await client
    .from("memberships")
    .select("organization_id")
    .eq("organization_id", organization)
    .limit(1);
  return !error && Array.isArray(data) && data.length === 1;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({});
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  try {
    const client = await memberClient(req);
    const event = JSON.parse(await readBoundedBody(req, MAX_PHOTO_REQUEST_BYTES));
    if (!event || typeof event !== "object" || Array.isArray(event)) return json({ error: "INVALID_REQUEST" }, 400);

    const organization = typeof event.organization_id === "string" ? event.organization_id : "";
    if (!uuid.test(organization) || !(await isMember(client, organization))) return json({ error: "UNAUTHORIZED" }, 403);

    const r2 = createR2Storage();
    if (event.kind === "photo.upload") {
      const photo = decodePhoto(event.content_type, event.data);
      const path = `${organization}/${crypto.randomUUID()}.${photo.extension}`;
      if (r2) {
        try {
          await r2.upload(path, photo.bytes, photo.contentType);
        } catch (error) {
          if (error instanceof R2Error) return json({ error: "PHOTO_UPLOAD_FAILED" }, 502);
          throw error;
        }
      } else {
        const { error } = await client.storage.from("product-photos").upload(path, photo.bytes, {
          contentType: photo.contentType,
          upsert: false,
        });
        if (error) throw new R2Error("PHOTO_UPLOAD_FAILED", 502);
      }
      return json({ photo_path: path });
    }

    if (event.kind === "photo.url") {
      if (!validPhotoPath(organization, event.photo_path)) return json({ error: "INVALID_PHOTO" }, 400);
      if (r2) {
        try {
          if (await r2.exists(event.photo_path)) return json({ url: await r2.signedUrl(event.photo_path, 300) });
        } catch (error) {
          if (error instanceof R2Error) return json({ error: "PHOTO_NOT_FOUND" }, 404);
          throw error;
        }
      }
      const { data, error } = await client.storage.from("product-photos").createSignedUrl(event.photo_path, 300);
      if (error || !data?.signedUrl) return json({ error: "PHOTO_NOT_FOUND" }, 404);
      return json({ url: data.signedUrl });
    }

    return json({ error: "INVALID_REQUEST" }, 400);
  } catch (error) {
    if (error instanceof PhotoError) return json({ error: error.message }, error.message === "UNAUTHORIZED" ? 401 : 400);
    if (error instanceof R2Error) return json({ error: error.code }, error.status);
    return json({ error: "PHOTO_STORAGE_FAILED" }, 502);
  }
});
