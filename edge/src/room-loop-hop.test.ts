import { describe, expect, it } from "vitest";
import { HOP_CAP, HOP_DECAY_S, MemoryRoomStore, RoomCore, type Caller } from "./room-core";

const ALICE: Caller = { userId: "u-alice" };

describe("RoomCore cross-channel loop hop accounting", () => {
  it("retains relay hops for at least an hour", () => {
    expect(HOP_DECAY_S).toBeGreaterThanOrEqual(3600);
  });

  it("carries monotonic parentHop across send_message -> post_room chains and stops wakes at HOP_CAP", async () => {
    const store = new MemoryRoomStore();
    const core = await RoomCore.create(store, "room_loop", "org-a", ALICE, {
      name: "build",
      kind: "persistent",
      member: "owner-mac",
      deviceId: "dev-mac"
    });
    await core.join(ALICE, { member: "codex-mac", kind: "graff", deviceId: "dev-mac" });
    await core.join(ALICE, { member: "claude-mac", kind: "graff", deviceId: "dev-mac" });

    const carried = await core.post(ALICE, {
      member: "codex-mac",
      deviceId: "dev-mac",
      body: "@claude-mac pong",
      kind: "message",
      parentHop: 4
    });
    expect(carried.message.hop).toBe(5);
    expect(carried.deliver).toHaveLength(1);

    const capped = await core.post(ALICE, {
      member: "claude-mac",
      deviceId: "dev-mac",
      body: "@codex-mac ping again",
      kind: "message",
      parentHop: HOP_CAP
    });
    expect(capped.message.hop).toBe(HOP_CAP);
    expect(capped.deliver).toEqual([]);
  });
});
