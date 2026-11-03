export const MAX_PHOTO_BYTES = 5 * 1024 * 1024;
export const MAX_PHOTO_REQUEST_BYTES = 7 * 1024 * 1024;

export class PhotoError extends Error {}

// Read a bounded stream, including requests sent without Content-Length.
export async function readBoundedBody(req: Request, maximum: number): Promise<string> {
  const declared = req.headers.get("content-length");
  if (declared && Number(declared) > maximum) throw new PhotoError("REQUEST_TOO_LARGE");
  const reader = req.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > maximum) {
        await reader.cancel();
        throw new PhotoError("REQUEST_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

const extensions: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

export function decodePhoto(contentType: unknown, data: unknown): { bytes: Uint8Array; extension: string; contentType: string } {
  if (typeof contentType !== "string" || !Object.hasOwn(extensions, contentType)) throw new PhotoError("INVALID_PHOTO_TYPE");
  if (typeof data !== "string" || data.length === 0 || data.length > Math.ceil(MAX_PHOTO_BYTES / 3) * 4) throw new PhotoError("PHOTO_TOO_LARGE");
  if (data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(data)) throw new PhotoError("INVALID_PHOTO_TYPE");
  let binary: string;
  try { binary = atob(data); } catch { throw new PhotoError("INVALID_PHOTO_TYPE"); }
  if (binary.length > MAX_PHOTO_BYTES) throw new PhotoError("PHOTO_TOO_LARGE");
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  const match = contentType === "image/jpeg"
    ? bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff
    : contentType === "image/png"
    ? bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => bytes[i] === v)
    : bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" && String.fromCharCode(...bytes.slice(8, 12)) === "WEBP";
  if (!match) throw new PhotoError("INVALID_PHOTO_TYPE");
  return { bytes, extension: extensions[contentType], contentType };
}

export function validPhotoPath(org: string, path: unknown): path is string {
  if (typeof path !== "string" || !path.startsWith(`${org}/`)) return false;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$/.test(path);
}
