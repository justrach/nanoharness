//! Per-native-context ownership: never global, so identical row keys in
//! another window cannot steal Copy or the return-to-editor route.
const ui = @import("nanoui").ui;
pub const State = struct {
    surface: u64 = 0,
    return_focus: u64 = 0,
    /// Only the exact deferred activation that completed this gesture may
    /// retain it through a focused/peer outlet swap.
    promoted_chat: u64 = 0,
    snapshot: u64 = 0,
};

/// Transcript row span pinned for a completed selection so offscreen unselected
/// history stays culled while Copy and highlight validation keep exact ownership.
pub const Pin = struct {
    surface: u64 = 0,
    anchor: u64 = 0,
    focus: u64 = 0,
    lo_row: u64 = 0,
    hi_row: u64 = 0,
};

/// Explicit child key under the implicit window root. The view calls this
/// only before/after building its tree; no pointer survives a memory rehash.
pub fn state(c: *ui.Context) *State {
    const depth = c.stack.items.len;
    c.stack.items.len = 1;
    defer c.stack.items.len = depth;
    const key = c.next_key;
    const integer = c.next_key_int;
    defer {
        c.next_key = key;
        c.next_key_int = integer;
    }
    ui.key(c, "window-selection-owner");
    return c.state(State, "ownership");
}

pub fn pin(c: *ui.Context) *Pin {
    const depth = c.stack.items.len;
    c.stack.items.len = 1;
    defer c.stack.items.len = depth;
    const key = c.next_key;
    const integer = c.next_key_int;
    defer {
        c.next_key = key;
        c.next_key_int = integer;
    }
    ui.key(c, "window-selection-owner");
    return c.state(Pin, "pin");
}
