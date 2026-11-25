/** Harness access tokens are short-lived JWTs issued after CodeGraff OAuth. */
import {
  EncryptJWT,
  SignJWT,
  importPKCS8,
  jwtDecrypt,
  jwtVerify,
  type JWTPayload
} from "jose";
import type { Env } from "./env";

export type TrustTier = "personal" | "sandbox";

export interface Verified {
  readonly userId: string;
  readonly sessionId?: string;
  readonly orgId?: string;
  readonly trustTier: TrustTier;
  readonly sandboxId?: string;
}

const ISSUER = "https://edge.codegraff.com";
const AUDIENCE = "harness-edge";
const REFRESH_AUDIENCE = "harness-edge-refresh";

const MAX_KEY_CACHE = 8;
const signingKeyCache = new Map<string, Uint8Array>();
const refreshKeyCache = new Map<string, Promise<Uint8Array>>();
const REFRESH_HKDF_INFO = new TextEncoder().encode("harness-refresh-v2");

const signingKey = (env: Env): Uint8Array | undefined => {
  const value = env.HARNESS_AUTH_SIGNING_KEY;
  if (!value || value.length < 32) return undefined;
  let encoded = signingKeyCache.get(value);
  if (!encoded) {
    if (signingKeyCache.size >= MAX_KEY_CACHE) {
      const oldest = signingKeyCache.keys().next().value;
      if (oldest !== undefined) signingKeyCache.delete(oldest);
    }
    encoded = new TextEncoder().encode(value);
    signingKeyCache.set(value, encoded);
  }
  return encoded;
};

export const personalOrgId = (userId: string): string => `user-${userId}`;

/** Access tokens last 15 minutes. Mutating chat2 / ControlRpc frames still
 * need a device signature, so a stolen `HARNESS_AUTH_SIGNING_KEY` is routing
 * only once clients enroll. */
export const ACCESS_TTL = "15m";

const eddsaKey = async (env: Env) => {
  const pem = env.HARNESS_AUTH_ED25519_PRIVATE;
  if (!pem || !pem.includes("BEGIN")) return undefined;
  try {
    return await importPKCS8(pem, "EdDSA");
  } catch {
    return undefined;
  }
};

export const issueToken = async (env: Env, userId: string): Promise<string> => {
  const claims = { org_id: personalOrgId(userId), trust_tier: "personal" };
  const ed = await eddsaKey(env);
  if (ed) {
    return new SignJWT(claims)
      .setProtectedHeader({ alg: "EdDSA" })
      .setIssuer(ISSUER)
      .setAudience(AUDIENCE)
      .setSubject(userId)
      .setIssuedAt()
      .setExpirationTime(ACCESS_TTL)
      .sign(ed);
  }
  const key = signingKey(env);
  if (!key) throw new Error("HARNESS_AUTH_SIGNING_KEY is not configured");
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(ACCESS_TTL)
    .sign(key);
};

export const issueSandboxToken = async (
  env: Env,
  userId: string,
  sandboxId?: string
): Promise<string> => {
  const key = signingKey(env);
  if (!key) throw new Error("HARNESS_AUTH_SIGNING_KEY is not configured");
  return new SignJWT({
    org_id: personalOrgId(userId),
    trust_tier: "sandbox",
    ...(sandboxId ? { sandbox_id: sandboxId } : {})
  })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(key);
};

// Shipped engines keep a stored session only if its refresh token starts with
// `harness_rt_`, so the prefix stays; the body's shape tells the formats
// apart (compact JWE has five segments, the legacy signed JWT three).
const REFRESH_PREFIX = "harness_rt_";
const segments = (token: string): number => token.split(".").length;

/** The refresh credential carries CodeGraff's refresh token, so it is
 * encrypted (JWE dir + A256GCM), not just signed: a signed JWT exposes the
 * token to anyone who reads the credential. The key is derived from the
 * signing secret under its own HKDF label so the two uses never share a key. */
const refreshEncryptionKey = async (env: Env): Promise<Uint8Array | undefined> => {
  const rawSecret = env.HARNESS_AUTH_SIGNING_KEY;
  const secret = signingKey(env);
  if (!rawSecret || !secret) return undefined;
  let derived = refreshKeyCache.get(rawSecret);
  if (!derived) {
    if (refreshKeyCache.size >= MAX_KEY_CACHE) {
      const oldest = refreshKeyCache.keys().next().value;
      if (oldest !== undefined) refreshKeyCache.delete(oldest);
    }
    derived = (async () => {
      const base = await crypto.subtle.importKey("raw", secret, "HKDF", false, ["deriveBits"]);
      const bits = await crypto.subtle.deriveBits(
        { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: REFRESH_HKDF_INFO },
        base,
        256
      );
      return new Uint8Array(bits);
    })();
    derived.catch(() => refreshKeyCache.delete(rawSecret));
    refreshKeyCache.set(rawSecret, derived);
  }
  return derived;
};

const refreshClaims = (payload: JWTPayload) => {
  if (typeof payload.sub !== "string" || !payload.sub ||
      typeof payload.codegraff_refresh_token !== "string" ||
      !payload.codegraff_refresh_token.startsWith("cg_rt_")) return undefined;
  return { userId: payload.sub, codegraffRefreshToken: payload.codegraff_refresh_token };
};

/** Bind CodeGraff's rotating refresh token to the identity verified at exchange. */
export const issueRefreshCredential = async (
  env: Env, userId: string, codegraffRefreshToken: string
): Promise<string> => {
  const key = await refreshEncryptionKey(env);
  if (!key) throw new Error("HARNESS_AUTH_SIGNING_KEY is not configured");
  const jwe = await new EncryptJWT({ codegraff_refresh_token: codegraffRefreshToken })
    .setProtectedHeader({ alg: "dir", enc: "A256GCM" })
    .setIssuer(ISSUER)
    .setAudience(REFRESH_AUDIENCE)
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime("30d")
    .encrypt(key);
  return `${REFRESH_PREFIX}${jwe}`;
};

export const verifyRefreshCredential = async (
  env: Env, credential: string
): Promise<{ userId: string; codegraffRefreshToken: string } | undefined> => {
  if (!credential.startsWith(REFRESH_PREFIX)) return undefined;
  const body = credential.slice(REFRESH_PREFIX.length);
  try {
    if (segments(body) === 5) {
      const key = await refreshEncryptionKey(env);
      if (!key) return undefined;
      const { payload } = await jwtDecrypt(body, key, {
        issuer: ISSUER,
        audience: REFRESH_AUDIENCE,
        keyManagementAlgorithms: ["dir"],
        contentEncryptionAlgorithms: ["A256GCM"]
      });
      return refreshClaims(payload);
    }
    // Legacy signed credentials stay valid for one more refresh so existing
    // sign-ins are not dropped; the refresh rotates the CodeGraff token they
    // carry and returns an encrypted credential in their place.
    if (segments(body) === 3) {
      const key = signingKey(env);
      if (!key) return undefined;
      const { payload } = await jwtVerify(body, key, {
        issuer: ISSUER,
        audience: REFRESH_AUDIENCE,
        algorithms: ["HS256"]
      });
      return refreshClaims(payload);
    }
    return undefined;
  } catch {
    return undefined;
  }
};

export const bearerFromRequest = (request: Request): string | undefined => {
  const header = request.headers.get("authorization");
  if (header?.toLowerCase().startsWith("bearer ")) return header.slice(7).trim();
  return new URL(request.url).searchParams.get("token") ?? undefined;
};

export const verifyToken = async (env: Env, token: string): Promise<Verified | undefined> => {
  if (env.AUTH_MODE === "dev") {
    if (!token) return undefined;
    const at = token.indexOf("@");
    if (at > 0) return { userId: token.slice(0, at), orgId: token.slice(at + 1), trustTier: "personal" };
    return { userId: token, trustTier: "personal" };
  }
  const claimsOf = (payload: JWTPayload): Verified | undefined => {
    if (typeof payload.sub !== "string" || !payload.sub) return undefined;
    const trustTier: TrustTier = payload.trust_tier === "sandbox" ? "sandbox" : "personal";
    const sandboxId = typeof payload.sandbox_id === "string" && payload.sandbox_id ? payload.sandbox_id : undefined;
    return {
      userId: payload.sub,
      orgId: typeof payload.org_id === "string" ? payload.org_id : undefined,
      trustTier,
      ...(sandboxId ? { sandboxId } : {})
    };
  };
  const ed = await eddsaKey(env);
  if (ed) {
    try {
      const { payload } = await jwtVerify(token, ed, {
        issuer: ISSUER,
        audience: AUDIENCE,
        algorithms: ["EdDSA"]
      });
      const claims = claimsOf(payload);
      if (claims) return claims;
    } catch {
      /* fall through to HS256 so a rotation can coexist */
    }
  }
  const key = signingKey(env);
  if (!key) return undefined;
  try {
    const { payload } = await jwtVerify(token, key, {
      issuer: ISSUER,
      audience: AUDIENCE,
      algorithms: ["HS256"]
    });
    return claimsOf(payload);
  } catch {
    return undefined;
  }
};

export const authenticate = async (env: Env, request: Request): Promise<Verified | undefined> => {
  const token = bearerFromRequest(request);
  return token ? verifyToken(env, token) : undefined;
};
