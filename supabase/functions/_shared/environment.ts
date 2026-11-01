type ReadEnvironment = (name: string) => string | undefined;

// Hosted runtimes inject named modern keys. Older/local runtimes may expose
// the legacy variables instead. None of these server secrets enter the app.
export function apiKey(
  kind: "publishable" | "secret",
  read: ReadEnvironment = (name) => Deno.env.get(name),
): string {
  const dictionary = read(kind === "publishable" ? "SUPABASE_PUBLISHABLE_KEYS" : "SUPABASE_SECRET_KEYS");
  const prefix = kind === "publishable" ? "sb_publishable_" : "sb_secret_";
  if (dictionary) {
    let keys: Record<string, unknown>;
    try {
      keys = JSON.parse(dictionary);
    } catch {
      throw new Error("SERVER_KEYS_INVALID");
    }
    if (!keys || typeof keys !== "object" || Array.isArray(keys)) throw new Error("SERVER_KEYS_INVALID");
    const key = [keys.default, ...Object.values(keys)].find((value) => typeof value === "string" && value.startsWith(prefix));
    if (typeof key === "string") return key;
  }
  const legacy = read(kind === "publishable" ? "SUPABASE_ANON_KEY" : "SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  throw new Error("SERVER_KEYS_MISSING");
}
