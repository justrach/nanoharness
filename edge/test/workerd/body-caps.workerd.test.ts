import { env } from "cloudflare:test";
import { expect, it } from "vitest";
import { AUTH_USER_HEADER } from "../../src/env";
import { MAX_ROW_BYTES } from "../../src/chat-log";
import { MAX_DEVICE_SIDECAR_BYTES } from "../../src/device-room";
import { VAULT_LIMITS } from "../../src/vault-room";

/** A device room its made-up owner has claimed, as a host's first dial does. */
const claimedDevice = async () => {
  const room = env.DEVICE_ROOMS.get(env.DEVICE_ROOMS.idFromName(crypto.randomUUID()));
  const dial = await room.fetch("https://test/ws?role=host", {
    headers: { [AUTH_USER_HEADER]: "owner", upgrade: "websocket" }
  });
  expect(dial.status).toBe(101);
  dial.webSocket!.accept();
  dial.webSocket!.close();
  return room;
};

it("a device sidecar takes a snapshot, and refuses an oversized or malformed one", async () => {
  const room = await claimedDevice();
  const post = (body: BodyInit) =>
    room.fetch("https://test/sidecar/repos", { method: "POST", headers: { [AUTH_USER_HEADER]: "owner" }, body });

  const stored = await post(JSON.stringify({ repos: ["synthetic"] }));
  expect(stored.status, await stored.text()).toBe(200);

  const oversized = await post(new Uint8Array(MAX_DEVICE_SIDECAR_BYTES + 1).fill(32));
  expect(oversized.status).toBe(413);
  expect(await oversized.json()).toEqual({ error: "too_large" });

  const malformed = await post("{not json");
  expect(malformed.status).toBe(400);
  expect(await malformed.json()).toEqual({ error: "bad_json" });

  // Neither refusal replaced what was stored.
  const read = await room.fetch("https://test/sidecar/repos", { headers: { [AUTH_USER_HEADER]: "owner" } });
  expect(await read.json()).toEqual({ repos: ["synthetic"] });
});

it("a chat's sidecar and the vault keep their limits through the bounded reader", async () => {
  const chat = env.CHAT_ROOMS.get(env.CHAT_ROOMS.idFromName(crypto.randomUUID()));
  const put = (body: BodyInit) =>
    chat.fetch("https://chat/tail", { method: "PUT", headers: { [AUTH_USER_HEADER]: "owner" }, body });
  const kept = await put(JSON.stringify({ tail: "synthetic" }));
  expect(kept.status, await kept.text()).toBe(200);
  const refused = await put(new Uint8Array(4 * 1024 * 1024 + 1));
  expect(refused.status).toBe(413);
  await refused.arrayBuffer();
  const tail = await chat.fetch("https://chat/tail", { headers: { [AUTH_USER_HEADER]: "owner" } });
  expect(await tail.json()).toEqual({ tail: "synthetic" });

  const vault = env.VAULT_ROOMS.get(env.VAULT_ROOMS.idFromName(crypto.randomUUID()));
  const big = await vault.fetch("https://vault/vault/devices", {
    method: "POST",
    headers: { [AUTH_USER_HEADER]: "owner" },
    body: new Uint8Array(VAULT_LIMITS.bodyBytes + 1)
  });
  expect(big.status).toBe(413);
  await big.arrayBuffer();
  // A bodyless read still answers.
  const state = await vault.fetch("https://vault/vault", { headers: { [AUTH_USER_HEADER]: "owner" } });
  expect(state.status, await state.text()).toBe(200);
});

it("refuses oversized payloads on chat /rows, registry /push-target + /push, and device /nudge", async () => {
  const chat = env.CHAT_ROOMS.get(env.CHAT_ROOMS.idFromName(crypto.randomUUID()));
  const bigRow = await chat.fetch("https://chat/rows?device=dev1&batchId=b1", {
    method: "POST",
    headers: { [AUTH_USER_HEADER]: "owner" },
    body: new Uint8Array(MAX_ROW_BYTES + 4097)
  });
  expect(bigRow.status).toBe(413);
  expect(await bigRow.json()).toEqual({ error: "too_large" });

  const reg = env.REGISTRY_ROOMS.get(env.REGISTRY_ROOMS.idFromName(crypto.randomUUID()));
  const bigPushTarget = await reg.fetch("https://reg/push-target?device=dev1", {
    method: "POST",
    headers: { [AUTH_USER_HEADER]: "owner" },
    body: new Uint8Array(32 * 1024).fill(32)
  });
  expect(bigPushTarget.status).toBe(413);
  expect(await bigPushTarget.json()).toEqual({ error: "too_large" });

  const bigPush = await reg.fetch("https://reg/push?device=dev1", {
    method: "POST",
    headers: { [AUTH_USER_HEADER]: "owner" },
    body: new Uint8Array(2 * 1024 * 1024 + 1).fill(32)
  });
  expect(bigPush.status).toBe(413);
  expect(await bigPush.json()).toEqual({ error: "too_large" });

  const device = await claimedDevice();
  const bigNudge = await device.fetch("https://test/nudge", {
    method: "POST",
    headers: { [AUTH_USER_HEADER]: "owner" },
    body: new Uint8Array(16 * 1024).fill(32)
  });
  expect(bigNudge.status).toBe(413);
  expect(await bigNudge.json()).toEqual({ error: "too_large" });
});
