import { apiKey } from "./environment.ts";

const env = (values: Record<string, string | undefined>) => (name: string) => values[name];
function equal(actual: string, expected: string) {
  if (actual !== expected) throw new Error("Unexpected key selection");
}
Deno.test("modern default keys take priority over legacy keys", () => {
  const read = env({ SUPABASE_PUBLISHABLE_KEYS: '{"default":"sb_publishable_test"}', SUPABASE_ANON_KEY: "legacy" });
  equal(apiKey("publishable", read), "sb_publishable_test");
});
Deno.test("named modern secret works without a default key", () => {
  equal(apiKey("secret", env({ SUPABASE_SECRET_KEYS: '{"backend":"sb_secret_test"}' })), "sb_secret_test");
});
Deno.test("legacy local runtimes remain supported", () => {
  equal(apiKey("secret", env({ SUPABASE_SERVICE_ROLE_KEY: "legacy-test" })), "legacy-test");
});
Deno.test("missing or malformed key configuration fails without leaking values", () => {
  for (const values of [{}, { SUPABASE_SECRET_KEYS: "not-json" }, { SUPABASE_SECRET_KEYS: "null" }]) {
    let rejected = false;
    try { apiKey("secret", env(values)); } catch (error) {
      rejected = error instanceof Error && error.message.startsWith("SERVER_KEYS_");
    }
    if (!rejected) throw new Error("Invalid configuration was accepted");
  }
});
