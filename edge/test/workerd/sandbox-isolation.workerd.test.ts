import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { handleFetch } from "../../src/router";
import { issueToken } from "../../src/auth";
import { sandboxExchange } from "../../src/codegraff";
import { encodeHlc, type Op, type Row } from "../../src/registry-core";
import type { Env } from "../../src/env";

const cgEnv = (): Env => ({ ...env, AUTH_MODE: "codegraff" } as unknown as Env);

const callWorker = (path: string, token: string, init: RequestInit = {}) => {
  const headers = new Headers(init.headers);
  headers.set("authorization", `Bearer ${token}`);
  return handleFetch(new Request(`https://edge.test${path}`, { ...init, headers }), cgEnv(), "#!/bin/sh\n");
};

const hlc = (tick: number, device = "mac-1") => encodeHlc(1_700_000_000_000 + tick, 0, device);

const op = (kind: string, id: string, set: Record<string, unknown>, tick = 1, device = "mac-1"): Op => ({
  kind,
  id,
  op: "upsert",
  set,
  hlc: hlc(tick, device)
});

const mintSandbox = async (userId: string, sandboxId: string): Promise<string> => {
  const token = `cg_lt_${"a".repeat(48)}`;
  const out = await sandboxExchange(
    cgEnv(),
    token,
    (async () => Response.json({ user_id: Number(userId), email: `u${userId}@synthetic.test`, sandbox_id: sandboxId })) as unknown as typeof fetch
  );
  return out.accessToken;
};

afterEach(() => vi.restoreAllMocks());

describe("sandbox trust-tier isolation across Worker and Durable Objects", () => {
  it("blocks sandbox tokens from personal vault, account deletion, session/workspace DOs, personal devices, and cross-device registry/chat2/blob state", async () => {
    const userId = "4201";
    const orgId = `user-${userId}`;
    const e = cgEnv();
    const personalToken = await issueToken(e, userId);
    const sbxAToken = await mintSandbox(userId, "cnd_alpha");
    const sbxBToken = await mintSandbox(userId, "cnd_beta");

    // Seed personal vault, personal device (`mac-1`), personal registry rows, and personal chat2/blob.
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const rawKey = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
    const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

    expect(
      (
        await callWorker("/vault/devices", personalToken, {
          method: "POST",
          body: JSON.stringify({
            deviceId: "mac-1",
            name: "Mac",
            publicKey: b64u(crypto.getRandomValues(new Uint8Array(32))),
            signingKey: b64u(rawKey),
            wrappedKey: b64u(crypto.getRandomValues(new Uint8Array(104)))
          })
        })
      ).status
    ).toBe(200);

    const macHost = await callWorker("/device/mac-1/ws?role=host", personalToken, {
      headers: { upgrade: "websocket" }
    });
    expect(macHost.status).toBe(101);
    macHost.webSocket!.accept();

    expect(
      (
        await callWorker("/device/mac-1/sidecar/repos", personalToken, {
          method: "POST",
          body: JSON.stringify({ repos: ["personal-repo"] })
        })
      ).status
    ).toBe(200);

    expect(
      (
        await callWorker(`/registry/${orgId}/push?device=mac-1`, personalToken, {
          method: "POST",
          body: JSON.stringify({
            batch: crypto.randomUUID(),
            ops: [
              op("devices", "mac-1", { name: "Personal Mac" }, 1),
              op("spaces", "s-mac", { deviceId: "mac-1", path: "/Users/synthetic/secret" }, 2),
              op("chats", "c-mac", { deviceId: "mac-1", title: "Private Chat" }, 3),
              op("sidebarPins", "c-mac", { pinned: true, orderKey: "a" }, 4),
              op("preferences", "theme", { mode: "dark" }, 5)
            ]
          })
        })
      ).status
    ).toBe(200);

    expect(
      (await callWorker("/chat2/c-mac/tail", personalToken, { method: "PUT", body: JSON.stringify({ tail: "personal" }) })).status
    ).toBe(200);
    expect(
      (await callWorker("/blob/c-mac/part-1", personalToken, { method: "PUT", body: "personal tool output" })).status
    ).toBe(200);

    // 1. Sandbox token MUST be denied (403) on personal endpoints and cross-device targets.
    const denied: [string, RequestInit?][] = [
      ["/vault", { headers: { "x-vault-device": "mac-1" } }],
      ["/vault/devices", { method: "POST", body: JSON.stringify({ deviceId: "rogue" }) }],
      ["/auth/account/delete", { method: "POST", body: JSON.stringify({ confirm: true }) }],
      [`/workspace/${orgId}/tail`, {}],
      [`/workspace/${orgId}/ws`, { headers: { upgrade: "websocket" } }],
      ["/session/c-mac/ws", { headers: { upgrade: "websocket" } }],
      ["/tail/c-mac", {}],
      ["/diff/c-mac", {}],
      ["/snapshot/c-mac", {}],
      ["/append/c-mac", { method: "POST", body: new Uint8Array([1]) }],
      ["/device/mac-1/ws?role=client", { headers: { upgrade: "websocket" } }],
      ["/device/mac-1/ws?role=host", { headers: { upgrade: "websocket" } }],
      ["/device/mac-1/sidecar/repos", {}],
      ["/device/mac-1/sidecar/repos", { method: "POST", body: JSON.stringify({ repos: ["pwned"] }) }],
      ["/device/mac-1/status", {}],
      ["/device/mac-1/nudge", { method: "POST", body: JSON.stringify({ chatId: "c-mac" }) }],
      [`/registry/${orgId}/reset`, { method: "POST" }],
      [`/registry/${orgId}/push-target?device=mac-1`, { method: "POST", body: JSON.stringify({ token: "apns" }) }],
      [
        `/registry/${orgId}/push?device=sbx-a`,
        {
          method: "POST",
          body: JSON.stringify({
            batch: crypto.randomUUID(),
            ops: [op("chats", "c-mac", { deviceId: "mac-1", title: "Hijacked" }, 99, "sbx-a")]
          })
        }
      ],
      [
        `/registry/${orgId}/push?device=sbx-a`,
        {
          method: "POST",
          body: JSON.stringify({
            batch: crypto.randomUUID(),
            ops: [op("preferences", "theme", { mode: "pwned" }, 99, "sbx-a")]
          })
        }
      ],
      ["/chat2/c-mac/tail", {}],
      ["/blob/c-mac/part-1", {}]
    ];

    for (const [path, init] of denied) {
      const res = await callWorker(path, sbxAToken, init);
      expect(res.status, `sandbox unexpectedly allowed on ${init?.method ?? "GET"} ${path}`).toBe(403);
      res.webSocket?.close();
    }

    // Spoofing inbound worker trust headers on a sandbox request must never bypass the tier check.
    const spoofed = await callWorker("/vault", sbxAToken, {
      headers: { "x-vault-device": "mac-1", "x-harness-auth-tier": "personal" }
    });
    expect(spoofed.status).toBe(403);

    // Reading registry as sandbox MUST NOT return personal rows or personal device presence.
    const sbxRowsRes = await callWorker(`/registry/${orgId}/rows?device=sbx-a&beat=1`, sbxAToken);
    expect(sbxRowsRes.status).toBe(200);
    const sbxRowsBody = (await sbxRowsRes.json()) as { rows: Row[]; presence: Record<string, number> };
    expect(sbxRowsBody.rows).toEqual([]);
    expect(sbxRowsBody.presence["mac-1"]).toBeUndefined();

    // 2. Legitimate sandbox workflow on its own device/chats/blobs still succeeds...
    const sbxHost = await callWorker("/device/sbx-a/ws?role=host", sbxAToken, {
      headers: { upgrade: "websocket" }
    });
    expect(sbxHost.status).toBe(101);
    sbxHost.webSocket!.accept();
    expect(
      (
        await callWorker("/device/sbx-a/sidecar/repos", sbxAToken, {
          method: "POST",
          body: JSON.stringify({ repos: ["sandbox-repo"] })
        })
      ).status
    ).toBe(200);
    expect(
      (
        await callWorker(`/registry/${orgId}/push?device=sbx-a`, sbxAToken, {
          method: "POST",
          body: JSON.stringify({
            batch: crypto.randomUUID(),
            ops: [
              op("devices", "sbx-a", { name: "Sandbox A" }, 10, "sbx-a"),
              op("spaces", "s-sbx", { deviceId: "sbx-a", path: "/workspace" }, 11, "sbx-a"),
              op("chats", "c-sbx", { deviceId: "sbx-a", title: "Sandbox Task" }, 12, "sbx-a")
            ]
          })
        })
      ).status
    ).toBe(200);
    expect(
      (await callWorker("/chat2/c-sbx/tail", sbxAToken, { method: "PUT", body: JSON.stringify({ tail: "sbx" }) })).status
    ).toBe(200);
    expect(
      (await callWorker("/blob/c-sbx/part-1", sbxAToken, { method: "PUT", body: "sbx output" })).status
    ).toBe(200);
    expect((await callWorker("/blob/c-sbx/part-1", sbxAToken)).status).toBe(200);

    // Personal client CAN create a chat hosted on `sbx-a`, and `sbx-a` CAN sync its chat2 room.
    expect(
      (
        await callWorker(`/registry/${orgId}/push?device=mac-1`, personalToken, {
          method: "POST",
          body: JSON.stringify({
            batch: crypto.randomUUID(),
            ops: [op("chats", "c-hosted", { deviceId: "sbx-a", title: "Hosted on Sandbox" }, 20, "mac-1")]
          })
        })
      ).status
    ).toBe(200);
    expect(
      (await callWorker("/chat2/c-hosted/tail", sbxAToken, { method: "PUT", body: JSON.stringify({ tail: "hosted" }) })).status
    ).toBe(200);

    // 3. A second sandbox (`cnd_beta`) CANNOT impersonate or read `cnd_alpha`.
    expect((await callWorker("/device/sbx-a/ws?role=host", sbxBToken, { headers: { upgrade: "websocket" } })).status).toBe(403);
    expect((await callWorker("/device/sbx-a/sidecar/repos", sbxBToken)).status).toBe(403);
    expect((await callWorker(`/registry/${orgId}/rows?device=sbx-a`, sbxBToken)).status).toBe(403);
    expect((await callWorker("/chat2/c-sbx/tail", sbxBToken)).status).toBe(403);
    expect((await callWorker("/blob/c-sbx/part-1", sbxBToken)).status).toBe(403);

    // 4. Personal client still reaches both devices cleanly.
    const personalToSbx = await callWorker("/device/sbx-a/ws?role=client", personalToken, {
      headers: { upgrade: "websocket" }
    });
    expect(personalToSbx.status).toBe(101);
    personalToSbx.webSocket!.accept();
    const allRows = ((await (await callWorker(`/registry/${orgId}/rows`, personalToken)).json()) as { rows: Row[] }).rows;
    expect(allRows.some((r) => r.kind === "chats" && r.id === "c-mac" && r.fields.title === "Private Chat")).toBe(true);
    expect(allRows.some((r) => r.kind === "chats" && r.id === "c-sbx")).toBe(true);

    macHost.webSocket!.close();
    sbxHost.webSocket!.close();
    personalToSbx.webSocket!.close();
  });
});
