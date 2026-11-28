import { describe, expect, it } from "vitest";
import { readCapped, readJsonCapped, withoutToken } from "./body";
import { handleAuthRoute, MAX_AUTH_BODY_BYTES } from "./auth-routes";
import { crashReportRoute, MAX_CRASH_UPLOAD_BYTES } from "./crash-reports";
import type { Env } from "./env";

/** A body sent in `chunk`-byte pieces with no declared length, counting what was read. */
const chunked = (total: number, chunk: number) => {
  const pulled = { bytes: 0, cancelled: false };
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (pulled.bytes >= total) return controller.close();
      const size = Math.min(chunk, total - pulled.bytes);
      controller.enqueue(new Uint8Array(size).fill(7));
      pulled.bytes += size;
    },
    cancel() {
      pulled.cancelled = true;
    }
  });
  const request = new Request("https://edge.test/upload", { method: "POST", body, duplex: "half" } as RequestInit);
  return { request, pulled };
};

describe("bounded request bodies", () => {
  it("refuses a body by its declared length without reading it", async () => {
    const { request, pulled } = chunked(1024, 256);
    request.headers.set("content-length", "5000");
    expect(await readCapped(request, 4096)).toBeUndefined();
    expect(pulled.bytes).toBeLessThanOrEqual(256);
    expect(pulled.cancelled).toBe(true);
  });

  it("stops reading an undeclared body once it outgrows the limit", async () => {
    const { request, pulled } = chunked(64 * 1024 * 1024, 64 * 1024);
    expect(await readCapped(request, 1024 * 1024)).toBeUndefined();
    // Nowhere near the 64 MiB on offer.
    expect(pulled.bytes).toBeLessThan(2 * 1024 * 1024);
    expect(pulled.cancelled).toBe(true);
  });

  it("returns exactly the bytes sent, declared or not, up to the limit itself", async () => {
    const exact = chunked(300_000, 4096).request;
    const read = await readCapped(exact, 300_000);
    expect(read?.byteLength).toBe(300_000);
    expect(read?.buffer.byteLength).toBe(300_000);
    expect(read?.every((b) => b === 7)).toBe(true);

    const declared = new Request("https://edge.test/upload", { method: "POST", body: new Uint8Array([1, 2, 3]) });
    expect([...(await readCapped(declared, 3))!]).toEqual([1, 2, 3]);
    expect(await readCapped(new Request("https://edge.test/upload", { method: "POST", body: new Uint8Array(4) }), 3)).toBeUndefined();
    expect((await readCapped(new Request("https://edge.test/read"), 16))?.byteLength).toBe(0);
  });

  it("tells an oversized JSON body from a malformed one", async () => {
    const post = (body: string) => new Request("https://edge.test/json", { method: "POST", body });
    expect(await readJsonCapped(post('{"ids":[1,2]}'), 64)).toEqual({ ok: true, value: { ids: [1, 2] } });
    expect(await readJsonCapped(post("{not json"), 64)).toEqual({ ok: false, error: "bad_json", status: 400 });
    expect(await readJsonCapped(post(JSON.stringify({ pad: "x".repeat(100) })), 64)).toEqual({
      ok: false,
      error: "too_large",
      status: 413
    });
  });

  it("drops only the token from a forwarded query", () => {
    expect(withoutToken("?after=12&device=synthetic")).toBe("?after=12&device=synthetic");
    expect(withoutToken("?token=synthetic-bearer&after=12&device=synthetic")).toBe("?after=12&device=synthetic");
    expect(withoutToken("?token=synthetic-bearer")).toBe("");
    expect(withoutToken("")).toBe("");
  });

  it("caps chunked bodies on unauthenticated /auth/* routes and /diagnostics/crash-reports", async () => {
    const fakeEnv = {
      CODEGRAFF_OAUTH_CLIENT_ID: "synthetic-client",
      HARNESS_AUTH_SIGNING_KEY: "synthetic-signing-key"
    } as unknown as Env;

    for (const path of ["/auth/exchange", "/auth/refresh", "/auth/sandbox"]) {
      const { request, pulled } = chunked(MAX_AUTH_BODY_BYTES * 8, 16 * 1024);
      const url = new URL(`https://edge.test${path}`);
      const res = await handleAuthRoute(
        new Request(url, { method: "POST", body: request.body, duplex: "half" } as RequestInit),
        fakeEnv,
        url
      );
      expect(res?.status, path).toBe(413);
      expect(await res?.json()).toEqual({ error: "too_large" });
      expect(pulled.bytes).toBeLessThan(MAX_AUTH_BODY_BYTES * 3);
      expect(pulled.cancelled).toBe(true);
    }

    const { request, pulled } = chunked(MAX_CRASH_UPLOAD_BYTES * 4, 64 * 1024);
    const crashRes = await crashReportRoute(
      new Request("https://edge.test/diagnostics/crash-reports", {
        method: "POST",
        body: request.body,
        duplex: "half"
      } as RequestInit),
      {},
      ["diagnostics", "crash-reports"],
      "user-1"
    );
    expect(crashRes?.status).toBe(413);
    expect(await crashRes?.json()).toEqual({ error: "too_large" });
    expect(pulled.bytes).toBeLessThan(MAX_CRASH_UPLOAD_BYTES * 2);
    expect(pulled.cancelled).toBe(true);
  });
});
