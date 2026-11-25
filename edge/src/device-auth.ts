/**
 * Device-bound envelopes on chat2 rows and ControlRpc payloads.
 *
 * Magic prefixes match crates/sync/src/device_crypto.rs:
 *   H2S1 + JSON envelope  (signed plaintext)
 *   H2E1 + JSON envelope  (signed ciphertext; edge stores ciphertext)
 *
 * The edge never decrypts. It attributes the row to envelope.deviceId after
 * verifying the Ed25519 signature against an enrolled key, and ignores
 * `?device=` when an envelope is present. Unsigned legacy rows still use
 * `?device=` so existing iOS clients keep working until they ship signing.
 */
export const MAGIC_SIGNED = "H2S1";
export const MAGIC_E2EE = "H2E1";
const ENVELOPE_TTL_MS = 60_000;

export interface DeviceEnvelope {
  deviceId: string;
  ts: number;
  nonce: string;
  sig: string;
  body: string;
}

export type AttributeResult =
  | { ok: true; device: string; enrolled?: boolean }
  | { ok: false; code: string; message: string };

const b64ToBytes = (s: string): Uint8Array | undefined => {
  try {
    const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
    const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return undefined;
  }
};

export const looksSigned = (bytes: Uint8Array): boolean => {
  if (bytes.byteLength < 4) return false;
  const magic = String.fromCharCode(bytes[0]!, bytes[1]!, bytes[2]!, bytes[3]!);
  return magic === MAGIC_SIGNED || magic === MAGIC_E2EE;
};

export const parseEnvelope = (bytes: Uint8Array): DeviceEnvelope | undefined => {
  if (!looksSigned(bytes)) return undefined;
  try {
    const json = new TextDecoder().decode(bytes.subarray(4));
    const env = JSON.parse(json) as DeviceEnvelope;
    if (typeof env.deviceId !== "string" || !env.deviceId) return undefined;
    if (typeof env.ts !== "number" || typeof env.nonce !== "string") return undefined;
    if (typeof env.sig !== "string" || typeof env.body !== "string") return undefined;
    return env;
  } catch {
    return undefined;
  }
};

const signMessage = async (deviceId: string, ts: number, nonce: string, body: Uint8Array): Promise<Uint8Array> => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", body));
  const prefix = new TextEncoder().encode(`${deviceId}|${ts}|${nonce}|`);
  const msg = new Uint8Array(prefix.length + digest.length);
  msg.set(prefix);
  msg.set(digest, prefix.length);
  return msg;
};

export const verifyEnvelopeSig = async (
  env: DeviceEnvelope,
  verifyingKeyB64: string
): Promise<boolean> => {
  const keyBytes = b64ToBytes(verifyingKeyB64);
  const sig = b64ToBytes(env.sig);
  const body = b64ToBytes(env.body);
  if (!keyBytes || keyBytes.length !== 32 || !sig || sig.length !== 64 || !body) return false;
  try {
    const key = await crypto.subtle.importKey("raw", keyBytes as BufferSource, "Ed25519", false, ["verify"]);
    const msg = await signMessage(env.deviceId, env.ts, env.nonce, body);
    return crypto.subtle.verify("Ed25519", key, sig as BufferSource, msg);
  } catch {
    return false;
  }
};

export class ReplayCache {
  private readonly seen = new Map<string, Map<string, number>>();

  admit(deviceId: string, nonce: string, ts: number, now: number): boolean {
    for (const [dev, bucket] of this.seen) {
      for (const [n, t] of bucket) {
        if (Math.abs(now - t) > ENVELOPE_TTL_MS) bucket.delete(n);
      }
      if (bucket.size === 0) this.seen.delete(dev);
    }
    const bucket = this.seen.get(deviceId) ?? new Map<string, number>();
    if (bucket.has(nonce)) return false;
    bucket.set(nonce, ts);
    this.seen.set(deviceId, bucket);
    return true;
  }
}

/** Attribute a chat2 push. `fallback` is `?device=` / hello.device (legacy). */
export const attributePushDevice = async (opts: {
  payload: Uint8Array;
  fallback: string;
  enrolledKey?: string;
  replay: ReplayCache;
  now?: number;
  requireDeviceAuth?: boolean;
}): Promise<AttributeResult> => {
  const now = opts.now ?? Date.now();
  const env = parseEnvelope(opts.payload);
  if (!env) {
    if (opts.requireDeviceAuth) {
      return { ok: false, code: "unsigned", message: "mutating chat2 rows must be device-signed" };
    }
    return { ok: true, device: opts.fallback };
  }
  if (Math.abs(now - env.ts) > ENVELOPE_TTL_MS) {
    return { ok: false, code: "replay", message: "stale device envelope" };
  }
  if (!opts.replay.admit(env.deviceId, env.nonce, env.ts, now)) {
    return { ok: false, code: "replay", message: "replayed device envelope" };
  }
  if (!opts.enrolledKey) {
    // First envelope from this device: trust the claimed id for attribution
    // only when we are not fail-closed. Hosts still verify signatures.
    if (opts.requireDeviceAuth) {
      return { ok: false, code: "unknown_device", message: "device is not enrolled" };
    }
    return { ok: true, device: env.deviceId };
  }
  if (!(await verifyEnvelopeSig(env, opts.enrolledKey))) {
    return { ok: false, code: "bad_signature", message: "device signature mismatch" };
  }
  return { ok: true, device: env.deviceId, enrolled: true };
};
