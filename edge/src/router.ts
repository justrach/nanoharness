import { authenticate, personalOrgId, type Verified } from "./auth";
import { handleAuthRoute } from "./auth-routes";
import {
  AUTH_SANDBOX_ID_HEADER,
  AUTH_TRUST_TIER_HEADER,
  AUTH_USER_HEADER,
  CHAT_HOST_SANDBOX_HEADER,
  ROOM_KIND_HEADER,
  type Env
} from "./env";
import { previewRoute } from "./preview-route";
import { AUTH_ORG_HEADER, roomActorStub, roomStore } from "./room-actor";
import { ROOM_ID, RoomError, memberKey, newRoomId } from "./room-core";
import { sweepExpiredRooms } from "./room-store-pg";
import { crashReportRoute } from "./crash-reports";
import { releaseRoute } from "./releases";
import { readCapped, readJsonCapped, withoutToken } from "./body";

const SOURCE_ARCHIVE = "/releases/harness-edge-source-0.1.0.tar.gz";

const ID_RE = /^[A-Za-z0-9_-]{1,128}$/;

/** `decodeURIComponent` that answers `undefined` for malformed %-escapes. */
const safeDecode = (segment: string): string | undefined => {
  try {
    return decodeURIComponent(segment);
  } catch {
    return undefined;
  }
};
/** Tool part ids are harness-minted (`tool-1`, `call_x`, `m1#c1`-style) —
 * wider than ID_RE but still no slashes, so a part id can't traverse keys. */
const PART_RE = /^[A-Za-z0-9._:#~-]{1,200}$/;
const MAX_TOOL_BLOB_BYTES = 1024 * 1024;

const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" }
  });

/** Forward into a DO with the verified user and trust tier stamped on the request. */
const forward = (
  ns: DurableObjectNamespace,
  name: string,
  request: Request,
  auth: Verified,
  path: string,
  search?: string,
  options?: { roomKind?: "workspace"; chatHostSandbox?: boolean }
): Promise<Response> => {
  const stub = ns.get(ns.idFromName(name));
  const url = new URL(request.url);
  url.pathname = path;
  if (search !== undefined) url.search = search;
  const headers = new Headers(request.headers);
  // Strip Worker-controlled headers before setting verified values so an
  // inbound request can never spoof room kind, user, trust tier, or sandbox id.
  headers.delete(ROOM_KIND_HEADER);
  headers.delete(AUTH_USER_HEADER);
  headers.delete(AUTH_TRUST_TIER_HEADER);
  headers.delete(AUTH_SANDBOX_ID_HEADER);
  headers.delete(CHAT_HOST_SANDBOX_HEADER);
  headers.set(AUTH_USER_HEADER, auth.userId);
  headers.set(AUTH_TRUST_TIER_HEADER, auth.trustTier);
  if (auth.sandboxId) headers.set(AUTH_SANDBOX_ID_HEADER, auth.sandboxId);
  if (options?.roomKind) headers.set(ROOM_KIND_HEADER, options.roomKind);
  if (options?.chatHostSandbox) headers.set(CHAT_HOST_SANDBOX_HEADER, "1");
  return stub.fetch(new Request(url.toString(), { ...requestInit(request), headers }));
};

const sandboxAdmitsChat = async (
  env: Env,
  auth: Verified,
  chatId: string,
  checkChatRoomOwner: boolean
): Promise<{ allowed: boolean; hostMatched: boolean }> => {
  const orgId = auth.orgId ?? personalOrgId(auth.userId);
  const regStub = env.REGISTRY_ROOMS.get(env.REGISTRY_ROOMS.idFromName(`reg1/${orgId}/${auth.userId}`));
  const hostRes = await regStub.fetch(
    `https://registry/internal/chat-host?chatId=${encodeURIComponent(chatId)}`,
    { headers: { [AUTH_USER_HEADER]: auth.userId } }
  );
  if (hostRes.ok) {
    const info = (await hostRes.json()) as { found?: boolean; tier?: string; sandboxId?: string };
    if (info.found) {
      const ok = info.tier === "sandbox" && (!info.sandboxId || info.sandboxId === (auth.sandboxId ?? ""));
      return { allowed: ok, hostMatched: ok };
    }
  }
  if (!checkChatRoomOwner) return { allowed: true, hostMatched: false };
  const chatStub = env.CHAT_ROOMS.get(env.CHAT_ROOMS.idFromName(`chat2/${chatId}`));
  const headers: Record<string, string> = {
    [AUTH_USER_HEADER]: auth.userId,
    [AUTH_TRUST_TIER_HEADER]: auth.trustTier
  };
  if (auth.sandboxId) headers[AUTH_SANDBOX_ID_HEADER] = auth.sandboxId;
  const ownerRes = await chatStub.fetch("https://chat/internal/owner", { headers });
  if (!ownerRes.ok) return { allowed: false, hostMatched: false };
  const owner = (await ownerRes.json()) as { allowed?: boolean };
  return { allowed: owner.allowed === true, hostMatched: false };
};

/** Largest request body a room route takes (the actor caps JSON at 64 KiB). */
const MAX_ROOM_BODY_BYTES = 64 * 1024;

/** Forward into a room's actor with the verified user and org stamped on.
 * The body is read here first, not streamed through: an actor that refuses
 * before reading it (a destroyed or missing room) would otherwise leave the
 * piped stream dangling, and the Worker throws "Can't read from request
 * stream after response has been sent" — under load that took the runtime
 * down. Room bodies are small, so buffering costs nothing. */
const forwardRoom = async (
  env: Env,
  roomId: string,
  request: Request,
  userId: string,
  orgId: string,
  path: string,
  search: URLSearchParams
): Promise<Response> => {
  let body: ArrayBuffer | undefined;
  if (request.method !== "GET" && request.method !== "HEAD") {
    const declared = Number(request.headers.get("content-length") ?? 0);
    if (declared > MAX_ROOM_BODY_BYTES) return json({ error: "too_large" }, 413);
    body = await request.arrayBuffer();
    if (body.byteLength > MAX_ROOM_BODY_BYTES) return json({ error: "too_large" }, 413);
  }
  const stub = roomActorStub(env.ROOM_ACTORS, roomId);
  const url = new URL(request.url);
  url.pathname = path;
  search.set("room", roomId);
  url.search = search.toString();
  const headers = new Headers(request.headers);
  headers.delete("content-length");
  headers.set(AUTH_USER_HEADER, userId);
  headers.set(AUTH_ORG_HEADER, orgId);
  return stub.fetch(new Request(url.toString(), { method: request.method, body, headers }));
};

const ROOM_GET = new Set(["state", "messages", "ws"]);
const ROOM_POST = new Set([
  "join", "leave", "post", "archive", "destroy", "invite", "accept", "decline", "remove", "wakes", "release"
]);

/** Agent rooms (room-actor.ts). Access is by grant to the verified user; the
 * listing, inbox, invites and wake queue read PostgreSQL directly, everything
 * else goes through the room's actor. */
const roomRoute = async (
  request: Request,
  env: Env,
  url: URL,
  parts: string[],
  auth: { userId: string; orgId?: string }
): Promise<Response | undefined> => {
  if (parts[0] !== "rooms" && parts[0] !== "room") return undefined;
  const orgId = auth.orgId ?? personalOrgId(auth.userId);
  const store = roomStore(env);
  if (!store) return json({ error: "rooms_unavailable" }, 503);
  const who = () =>
    memberKey({ member: url.searchParams.get("member"), device: url.searchParams.get("device") ?? "" });
  const limit = (fallback: number) =>
    Math.max(1, Math.min(Number(url.searchParams.get("limit") ?? fallback) || fallback, 200));
  try {
    if (parts[0] === "rooms" && parts.length === 1 && request.method === "GET") {
      const listFor = url.searchParams.has("member") ? who() : undefined;
      return json({ rooms: await store.listRooms(auth.userId, listFor) });
    }
    if (parts[0] === "rooms" && parts.length === 2 && request.method === "GET") {
      if (parts[1] === "inbox") return json({ items: await store.inbox(auth.userId, who(), limit(50)) });
      if (parts[1] === "invites") return json({ invites: await store.invites(auth.userId) });
      // Another person's agents woke this user's chats: their engine collects
      // and queues them, then acks.
      if (parts[1] === "wakes") return json({ wakes: await store.pendingWakes(auth.userId, limit(100)) });
    }
    if (parts[0] === "rooms" && parts[1] === "wakes" && parts[2] === "ack" && request.method === "POST") {
      const read = await readJsonCapped(request, MAX_ROOM_BODY_BYTES);
      if (!read.ok && read.error === "too_large") return json({ error: "too_large" }, 413);
      const body = (read.ok ? read.value : null) as { ids?: unknown; dropped?: unknown } | null;
      const ids = Array.isArray(body?.ids) ? body.ids.filter((id): id is number => Number.isInteger(id)).slice(0, 500) : [];
      await store.ackWakes(auth.userId, ids, Math.floor(Date.now() / 1000), body?.dropped === true);
      return json({ ok: true, acked: ids.length });
    }
    if (parts[0] === "rooms" && parts.length === 1 && request.method === "POST") {
      return await forwardRoom(env, newRoomId(), request, auth.userId, orgId, "/create", new URLSearchParams());
    }
    if (parts[0] === "room" && parts.length === 3 && ROOM_ID.test(parts[1])) {
      const allowed = request.method === "GET" ? ROOM_GET : request.method === "POST" ? ROOM_POST : undefined;
      if (allowed?.has(parts[2])) {
        if (parts[2] === "ws" && request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
          return json({ error: "expected websocket" }, 426);
        }
        const search = new URLSearchParams(url.search);
        search.delete("token");
        return await forwardRoom(env, parts[1], request, auth.userId, orgId, `/${parts[2]}`, search);
      }
    }
  } catch (err) {
    if (err instanceof RoomError) return json({ error: err.code, message: err.message }, err.status);
    console.error(JSON.stringify({ event: "rooms_error", error: String(err) }));
    return json({ error: "store_unavailable" }, 503);
  }
  return json({ error: "not_found" }, 404);
};

const requestInit = (request: Request): RequestInit => ({
  method: request.method,
  body: request.body
});

/** Carry the dialing engine's `&device=` through to the DO (socket
 * attribution in logs — the 2026-08-04 deaf socket was only identifiable by
 * reverse-engineering rotating IPv6 privacy addresses). Validated so a
 * hand-crafted value can't inject into log lines or the DO's query. */
const deviceParam = (url: URL): string => {
  const device = url.searchParams.get("device") ?? "";
  return ID_RE.test(device) ? `&device=${device}` : "";
};

export async function handleFetch(request: Request, env: Env, installSh: string): Promise<Response> {
  const url = new URL(request.url);
  const parts = url.pathname.split("/").filter(Boolean);

  if (url.pathname === "/health") {
    return json({ ok: true, auth: env.AUTH_MODE === "dev" ? "dev" : "codegraff", source: SOURCE_ARCHIVE });
  }
  if (url.pathname === "/source" && request.method === "GET") {
    return Response.redirect(new URL(SOURCE_ARCHIVE, url).toString(), 302);
  }

  // ── public install surface (served by edge.codegraff.com): the
  //    `curl | sh` installer and the release artifacts it downloads ───────
  if (url.pathname === "/install.sh" && (request.method === "GET" || request.method === "HEAD")) {
    return new Response(request.method === "HEAD" ? null : installSh, {
      headers: {
        "content-type": "application/x-sh",
        "cache-control": "public, max-age=0, must-revalidate"
      }
    });
  }
  const release = await releaseRoute(request, env, url, parts);
  if (release) return release;

  // ── CodeGraff auth routes (pre-bearer: exchange/refresh/callback have no
  //    access token yet; the org routes verify the bearer themselves) ─────
  const authRouted = await handleAuthRoute(request, env, url);
  if (authRouted) return authRouted;

  const auth = await authenticate(env, request);
  if (!auth) return json({ error: "unauthenticated" }, 401);

  const preview = previewRoute(request, env, auth);
  if (preview) return preview;

  const room = await roomRoute(request, env, url, parts, auth);
  if (room) return room;

  const crashes = await crashReportRoute(request, env, parts, auth.userId);
  if (crashes) return crashes;

  // ── login vault (docs/adr/0005): one room per user, named from the
  //    verified bearer only. The DO additionally requires a device
  //    signature on every write; path and query pass through unchanged
  //    because they are part of the signed string. ────────────────────────
  if (parts[0] === "vault") {
    if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
    return forward(env.VAULT_ROOMS, `vault1/${auth.userId}`, request, auth, url.pathname, url.search);
  }

  // ── session rooms ───────────────────────────────────────────────────────
  if (parts[0] === "session" && parts[1] && ID_RE.test(parts[1]) && parts[2] === "ws") {
    if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "expected websocket" }, 426);
    }
    // `s2/` = the previous identity migration: rooms are
    // claim-on-first-join per user id, and prod issued a fresh id for
    // everyone — a new namespace lets prod identities claim fresh rooms
    // while hosts re-upload doc state from their local snapshots (same
    // playbook as `ws3` below). Frame-level room ids stay the bare chatId.
    return forward(
      env.SESSION_ROOMS,
      `s2/${parts[1]}`,
      request,
      auth,
      "/ws",
      `?chatId=${parts[1]}${deviceParam(url)}`
    );
  }
  if (parts[0] === "tail" && parts[1] && ID_RE.test(parts[1]) && request.method === "GET") {
    if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
    return forward(env.SESSION_ROOMS, `s2/${parts[1]}`, request, auth, "/tail", "");
  }
  if (parts[0] === "stats" && parts[1] && ID_RE.test(parts[1]) && request.method === "GET") {
    if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
    return forward(env.SESSION_ROOMS, `s2/${parts[1]}`, request, auth, "/stats", "");
  }
  if (parts[0] === "diff" && parts[1] && ID_RE.test(parts[1])) {
    if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
    return forward(env.SESSION_ROOMS, `s2/${parts[1]}`, request, auth, "/diff", "");
  }
  if (parts[0] === "snapshot" && parts[1] && ID_RE.test(parts[1]) && request.method === "GET") {
    if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
    return forward(env.SESSION_ROOMS, `s2/${parts[1]}`, request, auth, "/snapshot", "");
  }
  if (parts[0] === "append" && parts[1] && ID_RE.test(parts[1]) && request.method === "POST") {
    if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
    return forward(env.SESSION_ROOMS, `s2/${parts[1]}`, request, auth, "/append", "");
  }

  // ── chat2 rooms (docs/chat2-sync.md B): dumb log relays, one per chat.
  //    Claim-on-first-join ownership enforced in the DO (chat ids are
  //    client-minted). The DO handles /ws, /checkpoint (GET Range-resumable
  //    + POST floor-guarded), host-published /tail + /diff sidecars,
  //    /stats, /reset. ──────────────────────────────────────────────────────
  if (parts[0] === "chat2" && parts[1] && ID_RE.test(parts[1]) && parts[2]) {
    const room = `chat2/${parts[1]}`;
    const routes: Record<string, string[]> = {
      checkpoint: ["GET", "POST"],
      // Pull/push over plain HTTPS (the airplane-wifi transport): GET
      // /rows?after= collapses connect→hello→state→rowsReq→backfill into
      // one round trip; POST /rows is the batchId-deduped push twin.
      rows: ["GET", "POST"],
      tail: ["GET", "PUT"],
      diff: ["GET", "PUT"],
      stats: ["GET"],
      reset: ["POST"]
    };
    const isWs = parts[2] === "ws" && parts.length === 3;
    const isHttp = parts.length === 3 && Boolean(routes[parts[2]]?.includes(request.method));
    if (!isWs && !isHttp) return json({ error: "not found" }, 404);
    let forwardOpts: { chatHostSandbox?: boolean } | undefined;
    if (auth.trustTier === "sandbox") {
      const check = await sandboxAdmitsChat(env, auth, parts[1], false);
      if (!check.allowed) return json({ error: "trust_tier_denied" }, 403);
      if (check.hostMatched) forwardOpts = { chatHostSandbox: true };
    }
    if (isWs) {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "expected websocket" }, 426);
      }
      return forward(
        env.CHAT_ROOMS,
        room,
        request,
        auth,
        "/ws",
        `?chatId=${parts[1]}${deviceParam(url)}`,
        forwardOpts
      );
    }
    // Query carries through (`seqCovered` on POST /checkpoint), as do
    // headers (`x-chat2-frontier`, `range`).
    return forward(env.CHAT_ROOMS, room, request, auth, `/${parts[2]}`, withoutToken(url.search), forwardOpts);
  }

  // ── workspace rooms (ARCHITECTURE §2.2/§6.1): same SessionRoom DO class;
  //    the caller's Harness org claim (`org_id`) must equal the URL's orgId,
  //    and the room itself is derived from the caller's OWN user id — the
  //    workspace doc (spaces, chats index, devices) is per-user; teammates
  //    in the same org can never address each other's rooms. ──────────────
  if (parts[0] === "workspace" && parts[1] && ID_RE.test(parts[1])) {
    const orgId = parts[1];
    if (auth.orgId !== orgId) return json({ error: "forbidden" }, 403);
    if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
    // `ws4` = the 2026-08-04 incident break: the ws3 instance's storage was
    // left with causally-broken update rows by the abort-thrash loop (acks
    // outran the debounced flush) and could not be trusted again even after
    // /reset-log; a name bump allocates a virgin DO. (`ws3` was the per-user
    // privacy break, `ws2` the spaces overhaul.) Legacy rooms are orphaned
    // (hibernated, ~zero cost). URL path stays `/workspace/:orgId/*`; the
    // name is worker-internal — clients echo their own roomId strings.
    const room = `ws4/${orgId}/${auth.userId}`;
    if (parts[2] === "ws") {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "expected websocket" }, 426);
      }
      return forward(
        env.SESSION_ROOMS,
        room,
        request,
        auth,
        "/ws",
        `?chatId=${encodeURIComponent(room)}${deviceParam(url)}`,
        { roomKind: "workspace" }
      );
    }
    if (parts[2] === "tail" && request.method === "GET") {
      return forward(env.SESSION_ROOMS, room, request, auth, "/tail", "", { roomKind: "workspace" });
    }
    // Observability: log/snapshot sizes for the per-user workspace room, so a
    // human can see whether the compaction budget is holding (org-membership
    // was already checked above; the DO bypasses the owner gate for
    // workspace kind).
    if (parts[2] === "stats" && request.method === "GET") {
      return forward(env.SESSION_ROOMS, room, request, auth, "/stats", "", { roomKind: "workspace" });
    }
    // Raw doc snapshot: the repair/reseed read (2026-08-04: a device stranded
    // behind the shallow-locked rebuild converges by replacing its local
    // workspace doc with this — see the incident repair recipe).
    if (parts[2] === "snapshot" && request.method === "GET") {
      return forward(env.SESSION_ROOMS, room, request, auth, "/snapshot", "", { roomKind: "workspace" });
    }
    // Operator wedge-break: clear a workspace room whose update log grew big
    // enough to CPU-reset the DO on every cold start (org-membership already
    // checked; state re-uploads from each device's local doc on rejoin).
    if (parts[2] === "reset-log" && request.method === "POST") {
      return forward(env.SESSION_ROOMS, room, request, auth, "/reset-log", "", { roomKind: "workspace" });
    }
    // Merge-safe repair write (the chat rooms' /append, for the workspace
    // doc): lets an operator seed a reset room with ONE compact
    // locally-exported history blob instead of waiting for every device to
    // re-upload its whole doc — the N-way redundant re-seed is what kept
    // ballooning the update log after the 2026-08-05 wedge breaks.
    if (parts[2] === "append" && request.method === "POST") {
      return forward(env.SESSION_ROOMS, room, request, auth, "/append", "", { roomKind: "workspace" });
    }
  }

  // ── registry rooms (docs/registry-sync.md): the row-table replacement for
  //    the Loro workspace doc. Same trust shape as /workspace: org claim
  //    must match the URL, room derived from the caller's OWN user id, DO
  //    trusts the stamped header. `reg1` = first registry generation. ─────
  if (parts[0] === "registry" && parts[1] && ID_RE.test(parts[1])) {
    const orgId = parts[1];
    if (auth.orgId !== orgId) return json({ error: "forbidden" }, 403);
    const room = `reg1/${orgId}/${auth.userId}`;
    if (parts[2] === "ws") {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "expected websocket" }, 426);
      }
      return forward(
        env.REGISTRY_ROOMS,
        room,
        request,
        auth,
        "/ws",
        `?${deviceParam(url).replace(/^&/, "")}`
      );
    }
    if (parts[2] === "stats" && request.method === "GET") {
      return forward(env.REGISTRY_ROOMS, room, request, auth, "/stats", "");
    }
    // Pull over plain HTTPS: `?since=` returns the same delta the WS
    // hello would (full table without it — the original repair read).
    // One round trip on any network that passes HTTPS at all, where the
    // WS upgrade needs 4 and a cooperative middlebox.
    if (parts[2] === "rows" && request.method === "GET") {
      return forward(env.REGISTRY_ROOMS, room, request, auth, "/rows", withoutToken(url.search));
    }
    // Push over plain HTTPS — the WS push's fallback twin (LWW clocks
    // make replays no-ops, so at-least-once delivery is safe).
    if (parts[2] === "push" && request.method === "POST") {
      return forward(env.REGISTRY_ROOMS, room, request, auth, "/push", withoutToken(url.search));
    }
    // A phone's APNs token + notification choices (POST), or removal on
    // sign-out / turning notifications off (DELETE). `?device=` required.
    if (parts[2] === "push-target" && (request.method === "POST" || request.method === "DELETE")) {
      if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
      return forward(env.REGISTRY_ROOMS, room, request, auth, "/push-target", withoutToken(url.search));
    }
    // Operator wipe. Unlike the CRDT rooms this needs no recipe: clients
    // detect the seq regression on their next hello and re-seed the table
    // from local rows with original clocks, automatically.
    if (parts[2] === "reset" && request.method === "POST") {
      if (auth.trustTier === "sandbox") return json({ error: "trust_tier_denied" }, 403);
      return forward(env.REGISTRY_ROOMS, room, request, auth, "/reset", "");
    }
  }

  // ── device rooms ────────────────────────────────────────────────────────
  if (parts[0] === "device" && parts[1] && ID_RE.test(parts[1])) {
    const deviceId = parts[1];
    if (parts[2] === "ws") {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return json({ error: "expected websocket" }, 426);
      }
      const role = url.searchParams.get("role") === "host" ? "host" : "client";
      if (auth.trustTier === "sandbox" && role !== "host") {
        return json({ error: "trust_tier_denied" }, 403);
      }
      const connId = url.searchParams.get("connId") ?? crypto.randomUUID();
      // `d2/` — same staging→prod identity break as `s2/` above.
      return forward(
        env.DEVICE_ROOMS,
        `d2/${deviceId}`,
        request,
        auth,
        "/ws",
        `?role=${role}&connId=${encodeURIComponent(connId)}`
      );
    }
    if (parts[2] === "sidecar" && parts[3] && /^[a-z0-9-]{1,64}$/.test(parts[3])) {
      return forward(env.DEVICE_ROOMS, `d2/${deviceId}`, request, auth, `/sidecar/${parts[3]}`, "");
    }
    if (parts[2] === "status") {
      return forward(env.DEVICE_ROOMS, `d2/${deviceId}`, request, auth, "/status", "");
    }
    // Durable command nudge (§7): "chat X has pending commands — open its
    // doc". Delivered live if the host is connected, else queued in the DO
    // and replayed on the host's next join.
    if (parts[2] === "nudge" && request.method === "POST") {
      return forward(env.DEVICE_ROOMS, `d2/${deviceId}`, request, auth, "/nudge", "");
    }
  }

  // ── R2 tool-output sidecar (docs/chat2-sync.md A2): full tool outputs
  //    and diffs live here, keyed `{chatId}/{partId}[.diff]`; the doc keeps
  //    only a one-line summary + this key. Straight R2, no DO involvement —
  //    the doc stays thin whether or not these uploads land. Per-user
  //    prefix = owner auth. ─────────────────────────────────────────────
  if (parts[0] === "blob" && parts.length === 3 && ID_RE.test(parts[1])) {
    // Percent-decode the part segment before validating: PART_RE allows
    // `#` (`m1#c1`-style harness ids), which HTTP clients cannot send raw
    // (fragment delimiter) — the host percent-encodes it. Decode-then-
    // validate keeps traversal shut: `%2F` decodes to `/`, fails PART_RE.
    const partId = safeDecode(parts[2]);
    if (partId === undefined || !PART_RE.test(partId)) {
      return json({ error: "bad part id" }, 400);
    }
    if (auth.trustTier === "sandbox") {
      const check = await sandboxAdmitsChat(env, auth, parts[1], true);
      if (!check.allowed) return json({ error: "trust_tier_denied" }, 403);
    }
    const key = `blob/${auth.userId}/${parts[1]}/${partId}`;
    if (request.method === "PUT") {
      // Outputs are 4KiB-capped at the harness boundary; diffs can run
      // larger but a sidecar entry is one tool result, never a dump.
      const body = await readCapped(request, MAX_TOOL_BLOB_BYTES);
      if (!body) return json({ error: "too_large" }, 413);
      await env.BLOBS.put(key, body, {
        httpMetadata: {
          contentType: request.headers.get("content-type") ?? "text/plain; charset=utf-8"
        }
      });
      return json({ ok: true, bytes: body.byteLength });
    }
    if (request.method === "GET" || request.method === "HEAD") {
      const object =
        request.method === "GET" ? await env.BLOBS.get(key) : await env.BLOBS.head(key);
      if (!object) return json({ error: "not_found" }, 404);
      const headers = new Headers();
      object.writeHttpMetadata(headers);
      headers.set("etag", object.httpEtag);
      // Re-resolved tool parts overwrite their key, so short-lived caching only.
      headers.set("cache-control", "private, max-age=300");
      const body =
        request.method === "GET" && "body" in object ? (object as R2ObjectBody).body : null;
      return new Response(body, { headers });
    }
  }

  // ── retired attachment mirror (clients ≤0.1.62): acknowledge and discard
  //    so old outboxes drain once instead of retrying the PUT forever ──────
  if (parts[0] === "attachments" && parts[1] && request.method === "PUT") {
    return json({ ok: true });
  }

  return json({ error: "not_found" }, 404);
}

export async function handleScheduled(env: Env): Promise<void> {
  if (!env.HYPERDRIVE) return;
  const ids = await sweepExpiredRooms(env, Math.floor(Date.now() / 1000));
  await Promise.all(
    ids.map((id) =>
      roomActorStub(env.ROOM_ACTORS, id)
        .fetch(`https://room/wipe?room=${id}`, { method: "POST" })
        .catch((err) => console.error(JSON.stringify({ event: "room_wipe_failed", room: id, error: String(err) })))
    )
  );
  if (ids.length > 0) console.log(JSON.stringify({ event: "rooms_swept", count: ids.length }));
}
