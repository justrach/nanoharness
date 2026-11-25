import { describe, expect, it } from "vitest";
import {
  MAGIC_SIGNED,
  ReplayCache,
  attributePushDevice,
  looksSigned,
  parseEnvelope
} from "./device-auth";

const encoder = new TextEncoder();

const unsigned = encoder.encode("plain loro bytes");

const envelopeBytes = (deviceId: string, ts = Date.now(), nonce = "n1"): Uint8Array => {
  const json = JSON.stringify({
    deviceId,
    ts,
    nonce,
    sig: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    body: "Zm9v"
  });
  const body = encoder.encode(json);
  const out = new Uint8Array(4 + body.length);
  out.set(encoder.encode(MAGIC_SIGNED));
  out.set(body, 4);
  return out;
};

describe("device-auth", () => {
  it("does not treat unsigned legacy rows as envelopes", () => {
    expect(looksSigned(unsigned)).toBe(false);
    expect(parseEnvelope(unsigned)).toBeUndefined();
  });

  it("attributes unsigned rows to ?device= until clients ship signing", async () => {
    const replay = new ReplayCache();
    const got = await attributePushDevice({
      payload: unsigned,
      fallback: "from-query",
      replay
    });
    expect(got).toEqual({ ok: true, device: "from-query" });
  });

  it("ignores ?device= when an envelope is present", async () => {
    const replay = new ReplayCache();
    const got = await attributePushDevice({
      payload: envelopeBytes("phone-1"),
      fallback: "spoofed-query",
      replay
    });
    expect(got.ok).toBe(true);
    if (got.ok) expect(got.device).toBe("phone-1");
  });

  it("rejects unsigned rows when device auth is required", async () => {
    const replay = new ReplayCache();
    const got = await attributePushDevice({
      payload: unsigned,
      fallback: "from-query",
      replay,
      requireDeviceAuth: true
    });
    expect(got.ok).toBe(false);
    if (!got.ok) expect(got.code).toBe("unsigned");
  });

  it("rejects replayed envelopes", async () => {
    const replay = new ReplayCache();
    const payload = envelopeBytes("phone-1", Date.now(), "once");
    const first = await attributePushDevice({ payload, fallback: "x", replay });
    expect(first.ok).toBe(true);
    const second = await attributePushDevice({ payload, fallback: "x", replay });
    expect(second.ok).toBe(false);
    if (!second.ok) expect(second.code).toBe("replay");
  });
});
