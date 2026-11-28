/-
  Nano/UiMode3.lean — 3-mode UX contract:
    - `.zen` (Dia-esque calm chat focus)
    - `.developer` (full workspace actions, filters, git, prompt rail)
    - `.design` (Paper-inspired canvas & design inspector)
-/

namespace Nano.UiMode3

inductive UiMode
  | zen
  | developer
  | design
deriving DecidableEq, Repr, BEq, Inhabited

structure ModePolicy where
  showsWorkspaceTree     : Bool
  showsMultiAxisFilters  : Bool
  showsRowTechBadges     : Bool
  showsGitCheckoutChrome : Bool
  showsPromptRail        : Bool
  showsActionToolbar     : Bool
  showsGroupedSections   : Bool
  showsDevTrailingToggles : Bool
  showsDesignCanvasToggle : Bool
  showsZenNewSessionBox  : Bool
  suppressesPromos       : Bool
  composerCornerRadius   : Nat
  trailingButtonCount    : Nat
deriving DecidableEq, Repr, BEq, Inhabited

def profileOf : UiMode → ModePolicy
  | .zen =>
    { showsWorkspaceTree := false
      showsMultiAxisFilters := false
      showsRowTechBadges := false
      showsGitCheckoutChrome := false
      showsPromptRail := false
      showsActionToolbar := false
      showsGroupedSections := false
      showsDevTrailingToggles := false
      showsDesignCanvasToggle := false
      showsZenNewSessionBox := true
      suppressesPromos := true
      composerCornerRadius := 16
      trailingButtonCount := 1 }
  | .developer =>
    { showsWorkspaceTree := true
      showsMultiAxisFilters := true
      showsRowTechBadges := true
      showsGitCheckoutChrome := true
      showsPromptRail := true
      showsActionToolbar := true
      showsGroupedSections := true
      showsDevTrailingToggles := true
      showsDesignCanvasToggle := false
      showsZenNewSessionBox := false
      suppressesPromos := false
      composerCornerRadius := 16
      trailingButtonCount := 3 }
  | .design =>
    { showsWorkspaceTree := false
      showsMultiAxisFilters := false
      showsRowTechBadges := false
      showsGitCheckoutChrome := false
      showsPromptRail := false
      showsActionToolbar := false
      showsGroupedSections := false
      showsDevTrailingToggles := false
      showsDesignCanvasToggle := true
      showsZenNewSessionBox := true
      suppressesPromos := true
      composerCornerRadius := 16
      trailingButtonCount := 2 }

def nextMode : UiMode → UiMode
  | .zen => .developer
  | .developer => .design
  | .design => .zen

def trailingReservePx (m : UiMode) (settingsOpen : Bool) : Nat :=
  if settingsOpen then 0
  else
    let p := profileOf m
    -- 28px per compact square/capsule trailing toggle + 4px inter-gap + 8px right margin
    8 + p.trailingButtonCount * 28 + (p.trailingButtonCount - 1) * 4

/-- Responsive trailing control count: shows all mode toggles when chrome width
    (`availPx >= 420`) and rightmost slot (`lastSlotPx >= 240`) have room;
    otherwise collapses to the single Panel toggle (`1`, 36px) so narrow windows
    and 3-column splits never clip tab labels or overflow pills. -/
def effectiveTrailingCount (m : UiMode) (settingsOpen : Bool) (availPx lastSlotPx : Nat) : Nat :=
  if settingsOpen then 0
  else match m with
    | .zen => 1
    | _ => if availPx >= 420 && lastSlotPx >= 240 then (profileOf m).trailingButtonCount else 1

def effectiveTrailingReservePx (m : UiMode) (settingsOpen : Bool) (availPx lastSlotPx : Nat) : Nat :=
  let cnt := effectiveTrailingCount m settingsOpen availPx lastSlotPx
  if cnt == 0 then 0
  else 8 + cnt * 28 + (cnt - 1) * 4

theorem cramped_slot_preserves_tab_budget (m : UiMode) (availPx lastSlotPx : Nat)
    (h : availPx < 420 ∨ lastSlotPx < 240) :
    effectiveTrailingReservePx m false availPx lastSlotPx = 36 := by
  unfold effectiveTrailingReservePx effectiveTrailingCount
  cases m
  · simp
  · have hnot : ¬(420 ≤ availPx ∧ 240 ≤ lastSlotPx) := by omega
    simp [Bool.and_eq_true, decide_eq_true_eq, hnot]
  · have hnot : ¬(420 ≤ availPx ∧ 240 ≤ lastSlotPx) := by omega
    simp [Bool.and_eq_true, decide_eq_true_eq, hnot]

theorem zen_has_zero_dev_chrome :
    let p := profileOf .zen
    p.showsWorkspaceTree = false ∧
    p.showsMultiAxisFilters = false ∧
    p.showsRowTechBadges = false ∧
    p.showsGitCheckoutChrome = false ∧
    p.showsPromptRail = false ∧
    p.showsActionToolbar = false ∧
    p.showsGroupedSections = false ∧
    p.showsDevTrailingToggles = false ∧
    p.suppressesPromos = true := by
  decide

theorem developer_enables_all_dev_chrome :
    let p := profileOf .developer
    p.showsWorkspaceTree = true ∧
    p.showsMultiAxisFilters = true ∧
    p.showsRowTechBadges = true ∧
    p.showsGitCheckoutChrome = true ∧
    p.showsPromptRail = true ∧
    p.showsActionToolbar = true ∧
    p.showsGroupedSections = true ∧
    p.showsDevTrailingToggles = true := by
  decide

theorem design_mode_enables_canvas_and_hides_dev_noise :
    let p := profileOf .design
    p.showsDesignCanvasToggle = true ∧
    p.showsWorkspaceTree = false ∧
    p.showsActionToolbar = false ∧
    p.suppressesPromos = true := by
  decide

theorem settings_open_hides_trailing (m : UiMode) :
    trailingReservePx m true = 0 := by
  rfl

theorem mode_cycle_period_3 (m : UiMode) :
    nextMode (nextMode (nextMode m)) = m := by
  cases m <;> rfl

theorem composer_radius_consistent (m : UiMode) :
    (profileOf m).composerCornerRadius = 16 := by
  cases m <;> rfl

theorem trailing_reserve_positive_when_chat_visible (m : UiMode) :
    trailingReservePx m false >= 36 := by
  cases m <;> decide

end Nano.UiMode3
