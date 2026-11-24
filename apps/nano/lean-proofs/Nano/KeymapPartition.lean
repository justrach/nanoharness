/-
  Nano/KeymapPartition.lean — Collision-free keybinding partition across:
  1. Fixed window navigation chords (`fixedWindowChords`)
  2. Composer editing reserved chords (`composerReservedChords`)
  3. Rebindable workspace actions (`defaultRebindableChords`)

  Guarantees that all 3 partitions are pairwise disjoint and `canBindShortcut`
  enforces collision freedom before accepting any user binding.
-/

namespace Nano.KeymapPartition

structure Chord where
  code  : Nat
  cmd   : Bool := false
  ctrl  : Bool := false
  alt   : Bool := false
  shift : Bool := false
deriving DecidableEq, Repr, BEq, Inhabited

-- Special key codes matching Nanoui conventions
def keyEsc   : Nat := 256
def keyEnter : Nat := 257
def keyLeft  : Nat := 258
def keyRight : Nat := 259
def keyUp    : Nat := 260
def keyDown  : Nat := 261
def keyTab   : Nat := 262
def keyBack  : Nat := 263
def keyDel   : Nat := 264

def cEsc   := keyEsc
def cEnter := keyEnter

/-- Fixed window chords that cannot be reassigned by user shortcuts. -/
def fixedWindowChords : List Chord :=
  [ { code := 'w'.toNat, cmd := true }
  , { code := 'k'.toNat, cmd := true }
  , { code := 'l'.toNat, cmd := true }
  , { code := 'q'.toNat, cmd := true }
  , { code := 'h'.toNat, cmd := true }
  , { code := 'm'.toNat, cmd := true }
  , { code := 'm'.toNat, cmd := true, shift := true }
  , { code := 'd'.toNat, cmd := true, alt := true }
  , { code := '='.toNat, cmd := true }
  , { code := '-'.toNat, cmd := true }
  , { code := '0'.toNat, cmd := true }
  , { code := '['.toNat, cmd := true }
  , { code := ']'.toNat, cmd := true }
  , { code := '['.toNat, cmd := true, shift := true }
  , { code := ']'.toNat, cmd := true, shift := true }
  , { code := '1'.toNat, ctrl := true }
  , { code := '2'.toNat, ctrl := true }
  , { code := '3'.toNat, ctrl := true }
  , { code := '4'.toNat, ctrl := true }
  , { code := '5'.toNat, ctrl := true }
  , { code := '6'.toNat, ctrl := true }
  , { code := '7'.toNat, ctrl := true }
  , { code := '8'.toNat, ctrl := true }
  , { code := '9'.toNat, ctrl := true }
  , { code := keyLeft,  cmd := true, alt := true }
  , { code := keyRight, cmd := true, alt := true }
  , { code := keyUp,    cmd := true, alt := true }
  , { code := keyDown,  cmd := true, alt := true }
  ]

/-- Chords reserved for the composer text field (`shortcuts.zig:reserved`). -/
def composerReservedChords : List Chord :=
  [ { code := 'a'.toNat, cmd := true }
  , { code := 'c'.toNat, cmd := true }
  , { code := 'v'.toNat, cmd := true }
  , { code := 'x'.toNat, cmd := true }
  , { code := 'z'.toNat, cmd := true }
  , { code := 'z'.toNat, cmd := true, shift := true }
  , { code := 'a'.toNat, ctrl := true }
  , { code := 'e'.toNat, ctrl := true }
  , { code := 'k'.toNat, ctrl := true }
  , { code := 'u'.toNat, ctrl := true }
  , { code := 'w'.toNat, ctrl := true }
  , { code := keyEnter }
  , { code := keyEnter, shift := true }
  ]

/-- Tagged default workspace shortcuts:
    0 = newSession (Cmd+N)
    1 = openProjectPicker (Cmd+O)
    2 = toggleSidebar (Cmd+B)
    3 = splitTerminal (Cmd+D)
    4 = splitTerminalDown (Cmd+Shift+D)
    5 = toggleTerminalDock (Cmd+J)
    6 = openSettings (Cmd+,)
    7 = findSession (Cmd+F)
    8 = appshot (Cmd+Shift+S) -/
def defaultRebindableChords : List (Nat × Chord) :=
  [ (0,  { code := 'n'.toNat, cmd := true })
  , (1,  { code := 'o'.toNat, cmd := true })
  , (2,  { code := 'b'.toNat, cmd := true })
  , (3,  { code := 'd'.toNat, cmd := true })
  , (4,  { code := 'd'.toNat, cmd := true, shift := true })
  , (5,  { code := 'j'.toNat, cmd := true })
  , (6,  { code := ','.toNat, cmd := true })
  , (7,  { code := 'f'.toNat, cmd := true })
  , (8,  { code := 's'.toNat, cmd := true, shift := true })
  ]

def memChord (c : Chord) (xs : List Chord) : Bool :=
  xs.any (· == c)

def hasConflict (candidate : Chord) (actionId : Nat) (bindings : List (Nat × Chord)) : Bool :=
  memChord candidate fixedWindowChords ||
  memChord candidate composerReservedChords ||
  bindings.any (fun p => p.1 != actionId && p.2 == candidate)

def canBindShortcut (candidate : Chord) (actionId : Nat) (bindings : List (Nat × Chord)) : Bool :=
  !hasConflict candidate actionId bindings

def defaultsPairwiseDisjoint : Bool :=
  let chords := defaultRebindableChords.map (·.2)
  chords.length == chords.eraseDups.length

theorem defaults_pairwise_disjoint : defaultsPairwiseDisjoint = true := by
  decide

theorem fixed_disjoint_from_reserved :
    fixedWindowChords.all (fun c => !memChord c composerReservedChords) = true := by
  decide

theorem defaults_disjoint_from_fixed :
    defaultRebindableChords.all (fun p => !memChord p.2 fixedWindowChords) = true := by
  decide

theorem defaults_disjoint_from_reserved :
    defaultRebindableChords.all (fun p => !memChord p.2 composerReservedChords) = true := by
  decide

theorem every_default_valid_to_bind :
    defaultRebindableChords.all (fun p => canBindShortcut p.2 p.1 defaultRebindableChords) = true := by
  decide

theorem canBind_rejects_fixed (c : Chord) (actionId : Nat) (bindings : List (Nat × Chord))
    (h : memChord c fixedWindowChords = true) :
    canBindShortcut c actionId bindings = false := by
  simp [canBindShortcut, hasConflict, h]

theorem canBind_rejects_reserved (c : Chord) (actionId : Nat) (bindings : List (Nat × Chord))
    (h : memChord c composerReservedChords = true) :
    canBindShortcut c actionId bindings = false := by
  simp [canBindShortcut, hasConflict, h]

end Nano.KeymapPartition
