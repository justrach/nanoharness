/-
  Nano/DesignCanvas.lean — Paper.design-inspired artboard viewport,
  concentric radius math, normalized spatial pin clamping, and DESIGN.md rule checks.
-/

namespace Nano.DesignCanvas

inductive ArtboardPreset
  | mobile
  | tablet
  | desktop
deriving DecidableEq, Repr, BEq, Inhabited

def presetSize : ArtboardPreset → Nat × Nat
  | .mobile  => (390, 844)
  | .tablet  => (768, 1024)
  | .desktop => (1440, 900)

def zoomMinPct : Nat := 25
def zoomMaxPct : Nat := 400

def clampZoomPct (z : Nat) : Nat :=
  min zoomMaxPct (max zoomMinPct z)

def stepZoomPct (z : Nat) (zoomIn : Bool) : Nat :=
  let next := if zoomIn then (z * 5) / 4 else (z * 4) / 5
  clampZoomPct (if zoomIn && next == z then z + 1 else next)

/-- Concentric inner radius (`DESIGN.md` rule 5: `outer - border - padding`). -/
def concentricInner (outer border pad : Nat) : Nat :=
  outer - (border + pad)

/-- Clamp normalized spatial callout pin coordinates to `[0, 1000]` permille inside artboard. -/
def clampPinPermille (px py : Nat) : Nat × Nat :=
  (min 1000 px, min 1000 py)

/-- Hit target rule (`DESIGN.md` rule 1: `>= 32px`). -/
def hitTargetValid (w h : Nat) : Bool :=
  w >= 32 && h >= 32

/-- Compact type scale (`DESIGN.md` rule 6: `11, 12, 13, 14, 16`). -/
def allowedTypeSize (px : Nat) : Bool :=
  px == 11 || px == 12 || px == 13 || px == 14 || px == 16

/-- Easing rule (`DESIGN.md` rule 3): linear only for spinners; ease transitions <= 250ms or multi-part < 800ms. -/
def motionValid (isSpinner isLinear isMultiPart : Bool) (durationMs : Nat) : Bool :=
  if isLinear then isSpinner
  else if isMultiPart then durationMs > 0 && durationMs < 800
  else durationMs > 0 && durationMs <= 250

/-- Contrast ratio x100 from integer relative luminances scaled `0..10000` (WCAG 2.1 `(L1 + 0.05)/(L2 + 0.05)`). -/
def contrastRatioX100 (lumA lumB : Nat) : Nat :=
  let lHi := max lumA lumB
  let lLo := min lumA lumB
  ((lHi + 500) * 100) / (lLo + 500)

def meetsWcagAA (lumA lumB : Nat) (largeText : Bool) : Bool :=
  contrastRatioX100 lumA lumB >= (if largeText then 300 else 450)

def auditScore (hitOk typeOk motionOk contrastOk : Bool) : Nat :=
  (if hitOk then 1 else 0) +
  (if typeOk then 1 else 0) +
  (if motionOk then 1 else 0) +
  (if contrastOk then 1 else 0)

theorem clampZoom_in_bounds (z : Nat) :
    25 <= clampZoomPct z ∧ clampZoomPct z <= 400 := by
  unfold clampZoomPct zoomMinPct zoomMaxPct
  omega

theorem stepZoom_in_bounds (z : Nat) (zoomIn : Bool) :
    25 <= stepZoomPct z zoomIn ∧ stepZoomPct z zoomIn <= 400 := by
  unfold stepZoomPct clampZoomPct zoomMinPct zoomMaxPct
  exact ⟨Nat.le_min.mpr ⟨by omega, Nat.le_max_left _ _⟩, Nat.min_le_left _ _⟩

theorem concentric_exact (outer border pad : Nat) (h : border + pad <= outer) :
    concentricInner outer border pad + border + pad = outer := by
  unfold concentricInner
  omega

theorem concentric_never_exceeds_outer (outer border pad : Nat) :
    concentricInner outer border pad <= outer := by
  unfold concentricInner
  omega

theorem pin_clamped_in_unit_square (px py : Nat) :
    (clampPinPermille px py).1 <= 1000 ∧ (clampPinPermille px py).2 <= 1000 := by
  unfold clampPinPermille
  omega

theorem preset_dimensions_positive (p : ArtboardPreset) :
    (presetSize p).1 >= 390 ∧ (presetSize p).2 >= 844 := by
  cases p <;> decide

theorem linear_non_spinner_forbidden (ms : Nat) :
    motionValid false true false ms = false ∧ motionValid false true true ms = false := by
  simp [motionValid]

theorem audit_score_bounded (a b c d : Bool) :
    auditScore a b c d <= 4 := by
  cases a <;> cases b <;> cases c <;> cases d <;> decide

end Nano.DesignCanvas
