/-
  Nano/OverlayMutex.lean — Mutual exclusion, layer hierarchy, scrim gating,
  and keyboard ownership across Nano's popovers, dialogs, palette, and sheets.

  Guarantees that:
  1. At most one foreground overlay owns keyboard input (`keepsKeyboard`).
  2. Tier-1 popovers/menus replace each other cleanly and toggle off on re-click,
     and can never preempt an active higher-tier modal dialog/palette/sheet.
  3. Any modal tier (`tier ≥ 2`) activates the scrim and blocks canvas clicks.
  4. Layer indices strictly increase with modal tier so painting matches hit order.
-/

namespace Nano.OverlayMutex

inductive OverlayKind
  | none
  | sessionSearch
  | contextPinned
  | agentWorkPinned
  | accountUsageOpen
  | starMenu
  | updatesPopover
  | actionMenu
  | filterMenu
  | moreMenu
  | spaceMenu
  | checkoutMenu
  | refMenu
  | chatMenu
  | linkMenu
  | stripMenu
  | accountMenu
  | modelPicker
  | customTheme
  | themeImport
  | closeChoice
  | settingsRecording
  | actionCommandReview
  | commandPalette
  | openChooser
  | projectSetup
  | setup
deriving DecidableEq, Repr, BEq, Inhabited

def allKinds : List OverlayKind :=
  [ .none, .sessionSearch, .contextPinned, .agentWorkPinned, .accountUsageOpen
  , .starMenu, .updatesPopover, .actionMenu, .filterMenu, .moreMenu, .spaceMenu
  , .checkoutMenu, .refMenu, .chatMenu, .linkMenu, .stripMenu, .accountMenu
  , .modelPicker, .customTheme, .themeImport, .closeChoice, .settingsRecording
  , .actionCommandReview, .commandPalette, .openChooser, .projectSetup, .setup ]

/-- Visual and preemption tier:
    0 = no overlay
    1 = non-blocking / light-dismiss popover or hover card
    2 = modal dialog
    3 = global command palette (Ctrl/Cmd+K)
    4 = blocking setup or chooser sheet -/
def tier : OverlayKind → Nat
  | .none => 0
  | .sessionSearch | .contextPinned | .agentWorkPinned | .accountUsageOpen
  | .starMenu | .updatesPopover | .actionMenu | .filterMenu | .moreMenu
  | .spaceMenu | .checkoutMenu | .refMenu | .chatMenu | .linkMenu
  | .stripMenu | .accountMenu | .modelPicker => 1
  | .customTheme | .themeImport | .closeChoice | .settingsRecording | .actionCommandReview => 2
  | .commandPalette => 3
  | .openChooser | .projectSetup | .setup => 4

def activeLayer (k : OverlayKind) : Nat :=
  match tier k with
  | 0 => 0
  | 1 => 4
  | 2 => 6
  | 3 => 7
  | _ => 8

def blocksBackgroundInput (k : OverlayKind) : Bool :=
  k != .none

def keepsKeyboard (k : OverlayKind) : Bool :=
  k != .none

def scrimActive (k : OverlayKind) : Bool :=
  tier k >= 2

def allowsCanvasClick (k : OverlayKind) : Bool :=
  k == .none

/-- Transition when opening `next` over `cur`. Passing `.none` dismisses unless a tier >= 2 modal is closed explicitly. -/
def openOverlay (cur next : OverlayKind) : OverlayKind :=
  if next == .none then .none
  else if tier cur <= 1 || tier next >= tier cur then next
  else cur

/-- Transition when toggling a trigger button for `target`. -/
def toggleOverlay (cur target : OverlayKind) : OverlayKind :=
  if cur == target then .none
  else openOverlay cur target

theorem toggle_twice_restores_none (target : OverlayKind) :
    toggleOverlay (toggleOverlay .none target) target = .none := by
  cases target <;> decide

theorem tier1_never_preempts_modal (cur next : OverlayKind)
    (hcur : tier cur >= 2) (hnext : tier next >= 1) (hnext1 : tier next <= 1) :
    openOverlay cur next = cur := by
  cases cur <;> cases next <;> simp_all [tier, openOverlay] <;> decide

theorem open_replaces_lower_or_equal (cur next : OverlayKind)
    (hcur : tier cur <= 1) (hne : next != .none) :
    openOverlay cur next = next := by
  cases cur <;> cases next <;> simp_all [tier, openOverlay] <;> decide

theorem blocks_equals_keeps_keyboard (k : OverlayKind) :
    blocksBackgroundInput k = keepsKeyboard k := by
  rfl

theorem scrim_implies_blocks_canvas (k : OverlayKind) (h : scrimActive k = true) :
    allowsCanvasClick k = false := by
  cases k <;> simp_all [scrimActive, tier, allowsCanvasClick] <;> decide

theorem layer_strictly_ordered (a b : OverlayKind) (h : tier a < tier b) :
    activeLayer a < activeLayer b := by
  cases a <;> cases b <;> simp_all [tier, activeLayer]

end Nano.OverlayMutex
