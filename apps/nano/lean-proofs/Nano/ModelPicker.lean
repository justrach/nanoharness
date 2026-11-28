/-
  Model-picker viewport and row bounds (`apps/nano/src/view_picker.zig`).

  This is the integer-point arithmetic model of the layout kernel, not a
  proof of IEEE 754 evaluation, animation scheduling, or renderer behavior.
  The Zig UI regression exercises the actual floating-point transition.
-/

namespace Nano.ModelPicker

def chrome : Int := 2 + 39 + 1 + 35 + 1 + 1 + 28
def minViewport : Int := 30
def maxCardHeight : Int := 640
def rowHeight : Int := 34
def trailingSpace : Int := 6
def overscan : Int := 3

def viewport (card : Int) : Int := max minViewport (card - chrome)

def clampedOffset (card rows rawOffset : Int) : Int :=
  min (max 0 rawOffset) (max 0 (rows * rowHeight + trailingSpace - viewport card))

def firstCandidate (card rows rawOffset : Int) : Int :=
  max 0 (clampedOffset card rows rawOffset - rowHeight) / rowHeight

def visibleCount (card : Int) : Int := (viewport card + rowHeight - 1) / rowHeight

def first (card rows rawOffset : Int) : Int := min rows (firstCandidate card rows rawOffset)

def last (card rows rawOffset : Int) : Int :=
  min rows (first card rows rawOffset + visibleCount card + overscan)

/-- Even when the card is too short for its chrome, the viewport stays
    positive. Placement caps the card at 640 points. -/
theorem viewport_bounds (card : Int) (hcard : card ≤ maxCardHeight) :
    minViewport ≤ viewport card ∧ viewport card ≤ 533 := by
  simp only [viewport, minViewport, maxCardHeight, chrome] at *
  omega

/-- Before the Zig conversion to unsigned indices, both rounded values
    are nonnegative and bounded. Allow room for the overscan addition. -/
theorem cast_bounds (card rows rawOffset : Int)
    (hcard : card ≤ maxCardHeight) (hrows : 0 ≤ rows) :
    0 ≤ firstCandidate card rows rawOffset ∧ firstCandidate card rows rawOffset ≤ rows ∧
    1 ≤ visibleCount card ∧ visibleCount card + overscan ≤ 19 := by
  have hv := viewport_bounds card hcard
  simp only [firstCandidate, clampedOffset, visibleCount, rowHeight, trailingSpace, overscan,
    minViewport] at *
  omega

/-- The slice and trailing spacer are safe, including with zero rows and a
    stale scroll offset. -/
theorem slice_bounds (card rows rawOffset : Int) (hrows : 0 ≤ rows) :
    0 ≤ first card rows rawOffset ∧ first card rows rawOffset ≤ last card rows rawOffset ∧
    last card rows rawOffset ≤ rows := by
  simp only [first, last, firstCandidate, visibleCount, viewport, minViewport, rowHeight,
    overscan]
  omega

/-- At the first frame of the Flint expansion, the old signed row count
    was negative. After the clamp the same card requests one visible row. -/
theorem compact_expansion_regression :
    (46 - chrome + rowHeight - 1) / rowHeight = -1 ∧ visibleCount 46 = 1 := by
  decide

end Nano.ModelPicker
