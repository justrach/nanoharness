/**
 * Harness-native edge Worker (design §2, ARCHITECTURE §6): JWT auth at the
 * edge, then forwarding into per-session, per-workspace, and per-device
 * Durable Objects. Also serves content-addressed R2 attachments (§1.2) and
 * the CodeGraff OAuth bridge.
 */
import type { Env } from "./env";
import { SessionRoom } from "./session-room";
import { PreviewRoom } from "./preview-room";
import { DeviceRoom } from "./device-room";
import { RegistryRoom } from "./registry-room";
import { ChatRoom } from "./chat-room";
import { VaultRoom } from "./vault-room";
import { AccountPurge } from "./account-purge";
import { RefreshLeeway } from "./refresh-leeway";
import { RoomActor } from "./room-actor";
import { handleFetch, handleScheduled } from "./router";
import installSh from "./install.sh";

export { SessionRoom, DeviceRoom, RegistryRoom, ChatRoom, PreviewRoom, VaultRoom, RoomActor, AccountPurge, RefreshLeeway };

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleFetch(request, env, installSh);
  },

  scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    return handleScheduled(env);
  }
} satisfies ExportedHandler<Env>;
