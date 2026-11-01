import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { json } from "../_shared/http.ts";
import { apiKey } from "../_shared/environment.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({});
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const publicKey = apiKey("publishable");
  const authorization = req.headers.get("Authorization") ?? "";
  const user = createClient(url, publicKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
  const { data: identity, error: authError } = await user.auth.getUser();
  if (authError || !identity.user) return json({ error: "UNAUTHORIZED" }, 401);
  try {
    const { organization_id, email, role = "operator" } = await req.json();
    if (typeof email !== "string" || typeof organization_id !== "string") return json({ error: "INVALID_INVITATION" }, 400);
    const { error } = await user.rpc("prepare_invitation", { p_org: organization_id, p_email: email, p_role: role });
    if (error) return json({ error: error.message }, error.message.includes("FORBIDDEN") ? 403 : 400);
    const admin = createClient(url, apiKey("secret"), { auth: { persistSession: false } });
    const { error: inviteError } = await admin.auth.admin.inviteUserByEmail(email.trim().toLowerCase(), {
      redirectTo: "io.lineboard.mobile://login-callback",
    });
    if (inviteError) {
      if (!["email_exists", "user_already_exists"].includes(inviteError.code ?? "")) {
        return json({ error: "EMAIL_DELIVERY_FAILED", detail: "Convite salvo. Tente reenviar em instantes." }, 502);
      }
      const { error: otpError } = await admin.auth.signInWithOtp({ email: email.trim().toLowerCase(), options: {
        shouldCreateUser: false, emailRedirectTo: "io.lineboard.mobile://login-callback",
      } });
      if (otpError) return json({ error: "EMAIL_DELIVERY_FAILED" }, 502);
    }
    return json({ sent: true });
  } catch {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
});
