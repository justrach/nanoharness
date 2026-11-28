/-
  Nano/HoverStability.lean — Zero-reflow hover stability invariants.

  Dia-esque rule: hovering a tab slot, sidebar row, or chip may animate
  background/icon opacity, never layout geometry or truncation budgets.
-/

namespace Nano.HoverStability

def tabPadTotal : Nat := 16

/-- Reserved trailing control slot width in a tab cell (`16px` close glyph when closeable in a cell ≥ 72px, else `0`).
    Depends ONLY on `(cellW, isActive, canClose)` — NEVER on `isHovered`. -/
def tabControlsReserve (cellW : Nat) (isActive canClose : Bool) : Nat :=
  if canClose && (isActive || cellW >= 72) && cellW >= 40 then 16 else 0

/-- Available width for the tab title text. Explicitly independent of hover state. -/
def tabLabelWidth (cellW : Nat) (isActive isHovered canClose : Bool) : Nat :=
  let _ := isHovered
  let res := tabControlsReserve cellW isActive canClose
  if cellW <= tabPadTotal + res then 0
  else cellW - tabPadTotal - res

/-- Close glyph opacity percentage (0..100). Hovering only fades the glyph in inside its reserved slot. -/
def tabCloseGlyphOpacityPct (isActive isHovered canClose : Bool) : Nat :=
  if !canClose then 0
  else if isHovered then 100
  else if isActive then 80
  else 0

/-- Sidebar row title width depends only on outer row width, horizontal padding, and right column reserve. -/
def sidebarTitleMaxW (rowW padL padR timeReserve : Nat) (isHovered : Bool) : Nat :=
  let _ := isHovered
  rowW - (padL + padR + timeReserve)

/-- Standard interactive control hit target floor (`DESIGN.md` rule 1: >= 32 px). -/
def hitTargetSize (w h : Nat) : Nat × Nat :=
  (max w 32, max h 32)

theorem tab_label_width_hover_invariant (cellW : Nat) (isActive canClose : Bool) :
    tabLabelWidth cellW isActive true canClose =
    tabLabelWidth cellW isActive false canClose := by
  rfl

theorem tab_controls_reserve_hover_matches (cellW : Nat) (isActive canClose : Bool) :
    tabControlsReserve cellW isActive canClose =
    tabControlsReserve cellW isActive canClose := by
  rfl

theorem tab_label_plus_controls_fits_cell (cellW : Nat) (isActive isHovered canClose : Bool)
    (h : cellW >= tabPadTotal) :
    tabPadTotal + tabLabelWidth cellW isActive isHovered canClose +
    tabControlsReserve cellW isActive canClose <= cellW := by
  unfold tabLabelWidth tabControlsReserve tabPadTotal at *
  dsimp only
  split <;> split <;> simp_all [Bool.and_eq_true, Bool.or_eq_true] <;> omega

theorem close_opacity_hover_monotone (isActive canClose : Bool) :
    tabCloseGlyphOpacityPct isActive false canClose <=
    tabCloseGlyphOpacityPct isActive true canClose := by
  cases isActive <;> cases canClose <;> decide

theorem sidebar_row_title_hover_invariant (rowW padL padR timeReserve : Nat) :
    sidebarTitleMaxW rowW padL padR timeReserve true =
    sidebarTitleMaxW rowW padL padR timeReserve false := by
  rfl

theorem hit_target_floor_respected (w h : Nat) :
    (hitTargetSize w h).1 >= 32 ∧ (hitTargetSize w h).2 >= 32 := by
  simp [hitTargetSize]
  omega

end Nano.HoverStability
