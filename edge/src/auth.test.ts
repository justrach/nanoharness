import { SignJWT } from "jose";
import { describe, expect, it } from "vitest";
import { issueRefreshCredential, issueToken, verifyRefreshCredential, verifyToken } from "./auth";
import type { Env } from "./env";

const env = { HARNESS_AUTH_SIGNING_KEY: "k".repeat(48) } as Env;
const other = { HARNESS_AUTH_SIGNING_KEY: "z".repeat(48) } as Env;
const CG = "cg_rt_secret-refresh-token";

describe("access token", () => {
  it("lasts fifteen minutes", async () => {
    const token = await issueToken(env, "42");
    const payload = JSON.parse(
      atob(token.split(".")[1]!.replace(/-/g, "+").replace(/_/g, "/"))
    ) as { iat: number; exp: number };
    expect(payload.exp - payload.iat).toBe(15 * 60);
    const verified = await verifyToken(env, token);
    expect(verified?.userId).toBe("42");
  });
});

describe("refresh credential", () => {
  it("is encrypted and keeps the prefix shipped engines accept", async () => {
    const credential = await issueRefreshCredential(env, "42", CG);
    expect(credential.startsWith("harness_rt_")).toBe(true);
    const body = credential.slice("harness_rt_".length);
    expect(body.split(".")).toHaveLength(5);
    const decoded = body
      .split(".")
      .map((part) => {
        try {
          return atob(part.replace(/-/g, "+").replace(/_/g, "/"));
        } catch {
          return "";
        }
      })
      .join("");
    expect(decoded.includes("cg_rt_")).toBe(false);
    expect(credential.includes("cg_rt_")).toBe(false);
  });

  it("round-trips", async () => {
    const credential = await issueRefreshCredential(env, "42", CG);
    expect(await verifyRefreshCredential(env, credential)).toEqual({
      userId: "42",
      codegraffRefreshToken: CG
    });
  });

  it("rejects another key and tampering", async () => {
    const credential = await issueRefreshCredential(env, "42", CG);
    expect(await verifyRefreshCredential(other, credential)).toBeUndefined();
    const flipped = credential.slice(0, -2) + (credential.endsWith("A") ? "B" : "A") + credential.slice(-1);
    expect(await verifyRefreshCredential(env, flipped)).toBeUndefined();
    expect(await verifyRefreshCredential(env, "harness_rt_a.b.c.d")).toBeUndefined();
    expect(await verifyRefreshCredential(env, "nope")).toBeUndefined();
  });

  it("still accepts a legacy signed credential for its one refresh", async () => {
    const jwt = await new SignJWT({ codegraff_refresh_token: CG })
      .setProtectedHeader({ alg: "HS256" })
      .setIssuer("https://edge.codegraff.com")
      .setAudience("harness-edge-refresh")
      .setSubject("42")
      .setIssuedAt()
      .setExpirationTime("30d")
      .sign(new TextEncoder().encode(env.HARNESS_AUTH_SIGNING_KEY));
    expect(await verifyRefreshCredential(env, `harness_rt_${jwt}`)).toEqual({
      userId: "42",
      codegraffRefreshToken: CG
    });
  });
});
