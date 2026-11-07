type EnvironmentReader = (name: string) => string | undefined;

const encoder = new TextEncoder();
const service = "s3";
const defaultRegion = "auto";

export class R2Error extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, status = 502) {
    super(code);
    this.name = "R2Error";
    this.code = code;
    this.status = status;
  }
}

export type R2Settings = {
  endpoint: URL;
  endpointPath: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
};

function readEnv(name: string): string | undefined {
  const value = Deno.env.get(name);
  return value?.trim() || undefined;
}

function encode(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
}

function hex(value: ArrayBuffer | Uint8Array): string {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function arrayBuffer(value: Uint8Array): ArrayBuffer {
  const copy = new ArrayBuffer(value.byteLength);
  new Uint8Array(copy).set(value);
  return copy;
}

async function digest(value: Uint8Array): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", arrayBuffer(value)));
}

async function hmac(key: Uint8Array, value: string | Uint8Array): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    arrayBuffer(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const data = typeof value === "string" ? encoder.encode(value) : value;
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, arrayBuffer(data)));
}

async function signingKey(secret: string, date: string, region: string): Promise<Uint8Array> {
  const dateKey = await hmac(encoder.encode(`AWS4${secret}`), date);
  const regionKey = await hmac(dateKey, region);
  const serviceKey = await hmac(regionKey, service);
  return hmac(serviceKey, "aws4_request");
}

function timestamp(date: Date): { amzDate: string; dateStamp: string } {
  const iso = date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
  return { amzDate: iso, dateStamp: iso.slice(0, 8) };
}

function canonicalHeaders(headers: Record<string, string>): { value: string; signed: string } {
  const entries = Object.entries(headers)
    .map(([name, value]) => [name.toLowerCase(), value.trim().replace(/\s+/g, " ")] as const)
    .sort(([left], [right]) => left.localeCompare(right));
  return {
    value: entries.map(([name, value]) => `${name}:${value}\n`).join(""),
    signed: entries.map(([name]) => name).join(";"),
  };
}

function canonicalQuery(parameters: Array<[string, string]>): string {
  return parameters
    .map(([name, value]) => [encode(name), encode(value)] as const)
    .sort(([leftName, leftValue], [rightName, rightValue]) => leftName.localeCompare(rightName) || leftValue.localeCompare(rightValue))
    .map(([name, value]) => `${name}=${value}`)
    .join("&");
}

function canonicalObjectPath(settings: R2Settings, key: string): string {
  const parts = key.split("/");
  if (!key || key.startsWith("/") || parts.some((part) => !part || part === "." || part === "..")) {
    throw new R2Error("INVALID_PHOTO", 400);
  }
  const prefix = settings.endpointPath === "/" ? "" : settings.endpointPath;
  return `${prefix}/${encode(settings.bucket)}/${parts.map(encode).join("/")}`;
}

function objectUrl(settings: R2Settings, key: string): URL {
  const url = new URL(settings.endpoint.toString());
  url.pathname = canonicalObjectPath(settings, key);
  return url;
}

function requestScope(dateStamp: string, settings: R2Settings): string {
  return `${dateStamp}/${settings.region}/${service}/aws4_request`;
}

async function authorization(
  settings: R2Settings,
  method: string,
  url: URL,
  headers: Record<string, string>,
  payloadHash: string,
  date: Date,
): Promise<string> {
  const { amzDate, dateStamp } = timestamp(date);
  const canonical = canonicalHeaders({ ...headers, host: url.host });
  const request = [
    method,
    url.pathname,
    "",
    canonical.value,
    canonical.signed,
    payloadHash,
  ].join("\n");
  const scope = requestScope(dateStamp, settings);
  const stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, await digest(encoder.encode(request))].join("\n");
  const signature = hex(await hmac(await signingKey(settings.secretAccessKey, dateStamp, settings.region), stringToSign));
  return `AWS4-HMAC-SHA256 Credential=${settings.accessKeyId}/${scope}, SignedHeaders=${canonical.signed}, Signature=${signature}`;
}

export function r2Settings(read: EnvironmentReader = readEnv): R2Settings | null {
  const accountId = read("R2_ACCOUNT_ID") || read("CLOUDFLARE_ACCOUNT_ID");
  const endpointValue = read("R2_ENDPOINT") || (accountId ? `https://${accountId}.r2.cloudflarestorage.com` : undefined);
  const bucket = read("R2_BUCKET");
  const accessKeyId = read("R2_ACCESS_KEY_ID");
  const secretAccessKey = read("R2_SECRET_ACCESS_KEY");
  const configured = [endpointValue, bucket, accessKeyId, secretAccessKey].some(Boolean);
  if (!configured) return null;
  if (!endpointValue || !bucket || !accessKeyId || !secretAccessKey) throw new R2Error("R2_NOT_CONFIGURED", 503);

  let endpoint: URL;
  try {
    endpoint = new URL(endpointValue);
  } catch {
    throw new R2Error("R2_INVALID_CONFIG", 503);
  }
  if (endpoint.protocol !== "https:" || endpoint.search || endpoint.hash || endpoint.username || endpoint.password) {
    throw new R2Error("R2_INVALID_CONFIG", 503);
  }
  const endpointPath = endpoint.pathname.replace(/\/+$/, "") || "/";
  return {
    endpoint,
    endpointPath,
    bucket,
    accessKeyId,
    secretAccessKey,
    region: read("R2_REGION") || defaultRegion,
  };
}

export class R2Storage {
  private readonly settings: R2Settings;

  constructor(settings: R2Settings) {
    this.settings = settings;
  }

  async upload(key: string, body: Uint8Array, contentType: string): Promise<void> {
    const url = objectUrl(this.settings, key);
    const date = new Date();
    const { amzDate } = timestamp(date);
    const payloadHash = await digest(body);
    const headers = {
      "content-type": contentType,
      "x-amz-content-sha256": payloadHash,
      "x-amz-date": amzDate,
    };
    const auth = await authorization(this.settings, "PUT", url, headers, payloadHash, date);
    const response = await fetch(url, {
      method: "PUT",
      headers: { ...headers, authorization: auth },
      body: arrayBuffer(body),
    });
    if (!response.ok) throw new R2Error("R2_UPLOAD_FAILED", 502);
  }

  async exists(key: string): Promise<boolean> {
    const url = await this.signedRequestUrl(key, "HEAD", 60);
    const response = await fetch(url, { method: "HEAD" });
    if (response.status === 404) return false;
    if (!response.ok) throw new R2Error("R2_READ_FAILED", 502);
    return true;
  }

  async signedUrl(key: string, expiresInSeconds: number): Promise<string> {
    return this.signedRequestUrl(key, "GET", expiresInSeconds);
  }

  async signedRequestUrl(key: string, method: string, expiresInSeconds: number): Promise<string> {
    if (!Number.isInteger(expiresInSeconds) || expiresInSeconds < 1 || expiresInSeconds > 604800) {
      throw new R2Error("R2_INVALID_EXPIRY", 500);
    }
    const url = objectUrl(this.settings, key);
    const date = new Date();
    const { amzDate, dateStamp } = timestamp(date);
    const scope = requestScope(dateStamp, this.settings);
    const parameters: Array<[string, string]> = [
      ["X-Amz-Algorithm", "AWS4-HMAC-SHA256"],
      ["X-Amz-Credential", `${this.settings.accessKeyId}/${scope}`],
      ["X-Amz-Date", amzDate],
      ["X-Amz-Expires", String(expiresInSeconds)],
      ["X-Amz-SignedHeaders", "host"],
    ];
    const query = canonicalQuery(parameters);
    const request = [method, url.pathname, query, `host:${url.host}\n`, "host", "UNSIGNED-PAYLOAD"].join("\n");
    const stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, await digest(encoder.encode(request))].join("\n");
    const signature = hex(await hmac(await signingKey(this.settings.secretAccessKey, dateStamp, this.settings.region), stringToSign));
    return `${url.origin}${url.pathname}?${query}&X-Amz-Signature=${signature}`;
  }
}

export function createR2Storage(read: EnvironmentReader = readEnv): R2Storage | null {
  const settings = r2Settings(read);
  return settings ? new R2Storage(settings) : null;
}
