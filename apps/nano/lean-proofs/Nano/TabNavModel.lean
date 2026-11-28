/-
  Nano/TabNavModel.lean — Unified flat tab cycling and browser-grade
  non-destructive Back/Forward history navigation.
-/

namespace Nano.TabNavModel

def stepFlatTab (total cur : Nat) (forward : Bool) : Nat :=
  if total <= 1 then (if total == 0 then 0 else min cur (total - 1))
  else
    let c := min cur (total - 1)
    if forward then (c + 1) % total
    else (c + total - 1) % total

theorem stepFlatTab_in_bounds (total cur : Nat) (fwd : Bool) (ht : total > 0) :
    stepFlatTab total cur fwd < total := by
  unfold stepFlatTab
  by_cases h1 : total <= 1
  · have : total = 1 := by omega
    subst this
    simp
  · simp [h1]
    split <;> exact Nat.mod_lt _ ht

theorem stepFlatTab_roundtrip (total cur : Nat) (ht : total > 0) (hc : cur < total) :
    stepFlatTab total (stepFlatTab total cur true) false = cur := by
  unfold stepFlatTab
  by_cases h1 : total <= 1
  · have : total = 1 := by omega
    subst this
    have : cur = 0 := by omega
    subst this
    simp
  · simp [h1]
    have hmin : min cur (total - 1) = cur := by omega
    rw [hmin]
    have hmod : (cur + 1) % total < total := Nat.mod_lt _ ht
    have hmin2 : min ((cur + 1) % total) (total - 1) = (cur + 1) % total := by omega
    rw [hmin2]
    by_cases htop : cur + 1 = total
    · rw [htop, Nat.mod_self]
      have h0 : 0 + total - 1 = total - 1 := by omega
      rw [h0, Nat.mod_eq_of_lt (by omega)]
      omega
    · have hlt : cur + 1 < total := by omega
      rw [Nat.mod_eq_of_lt hlt]
      have hsub : cur + 1 + total - 1 = cur + total := by omega
      rw [hsub, Nat.add_mod_right, Nat.mod_eq_of_lt hc]

structure NavHistory where
  entries : List Nat
  index : Nat
deriving DecidableEq, Repr, BEq, Inhabited

def canBack (h : NavHistory) : Bool :=
  h.index > 0 && h.index < h.entries.length

def canForward (h : NavHistory) : Bool :=
  h.index + 1 < h.entries.length

/-- Push a newly opened destination: skips consecutive duplicate of current entry,
    truncates any forward tail past `h.index` (Dia/browser semantics), caps length at `maxCap` (≥ 1). -/
def pushHistory (maxCap : Nat) (h : NavHistory) (entry : Nat) : NavHistory :=
  if h.entries.isEmpty then
    { entries := [entry], index := 0 }
  else
    let curIdx := min h.index (h.entries.length - 1)
    if h.entries[curIdx]? == some entry then
      { entries := h.entries, index := curIdx }
    else
      let prefixEntries := h.entries.take (curIdx + 1)
      let appended := prefixEntries ++ [entry]
      let cap := max 1 maxCap
      let trimmed := if appended.length > cap then appended.drop (appended.length - cap) else appended
      { entries := trimmed, index := trimmed.length - 1 }

def goBack (h : NavHistory) : NavHistory :=
  if h.index > 0 && h.index < h.entries.length then { h with index := h.index - 1 } else h

def goForward (h : NavHistory) : NavHistory :=
  if h.index + 1 < h.entries.length then { h with index := h.index + 1 } else h

theorem goBack_goForward_inverse (h : NavHistory) (hb : canBack h = true) :
    goForward (goBack h) = h := by
  cases h with | mk entries index =>
  unfold canBack at hb
  simp only [Bool.and_eq_true, decide_eq_true_eq] at hb
  unfold goBack goForward
  have h1 : (index > 0 && index < entries.length) = true := by simp [hb.1, hb.2]
  have hf : index - 1 + 1 < entries.length := by omega
  simp [h1, hf]
  omega

theorem push_truncates_forward (maxCap : Nat) (h : NavHistory) (entry : Nat)
    (hdiff : h.entries[min h.index (h.entries.length - 1)]? ≠ some entry)
    (hne : ¬h.entries.isEmpty) :
    canForward (pushHistory maxCap h entry) = false := by
  unfold pushHistory canForward
  simp only [hne, Bool.false_eq_true, ↓reduceIte]
  have hbeq : (h.entries[min h.index (h.entries.length - 1)]? == some entry) = false := by
    cases hq : h.entries[min h.index (h.entries.length - 1)]? <;> simp_all
  rw [hbeq]
  simp only [Bool.false_eq_true, ↓reduceIte]
  split
  · have hdrop : 0 < ((h.entries.take (min h.index (h.entries.length - 1) + 1) ++ [entry]).drop
      ((h.entries.take (min h.index (h.entries.length - 1) + 1) ++ [entry]).length - max 1 maxCap)).length := by
      simp [List.length_drop]
      omega
    simp only [decide_eq_false_iff_not]
    omega
  · have hlen2 : 0 < (h.entries.take (min h.index (h.entries.length - 1) + 1) ++ [entry]).length := by simp
    simp only [decide_eq_false_iff_not]
    omega

theorem push_preserves_nonempty_bounds (maxCap : Nat) (h : NavHistory) (entry : Nat) :
    (pushHistory maxCap h entry).index < (pushHistory maxCap h entry).entries.length := by
  unfold pushHistory
  cases hl : h.entries with
  | nil => simp
  | cons x xs =>
    simp only [List.isEmpty_cons, Bool.false_eq_true, ↓reduceIte]
    split
    · simp only [List.length_cons]
      omega
    · split
      · simp [List.length_drop]; omega
      · simp

/-! Session-list selection (App.openChatInTab). The open conversations are
    flattened to their identities without counting empty draft slots. -/

def openTabs (tabs : List Nat) (id : Nat) : List Nat :=
  if id ∈ tabs then tabs else tabs ++ [id]

theorem focusing_existing_preserves_slots (tabs : List Nat) (id : Nat) (h : id ∈ tabs) :
    openTabs tabs id = tabs := by
  simp [openTabs, h]

theorem opening_adds_one (tabs : List Nat) (id : Nat) (h : id ∉ tabs) :
    (openTabs tabs id).length = tabs.length + 1 := by
  simp [openTabs, h]

theorem opening_preserves_unique (tabs : List Nat) (id : Nat) (hu : tabs.Nodup) :
    (openTabs tabs id).Nodup := by
  by_cases h : id ∈ tabs
  · simpa [openTabs, h] using hu
  · simp [openTabs, h, List.nodup_append, hu]
    intro a ha eq
    exact h (eq ▸ ha)

theorem repeat_open_preserves_slots (tabs : List Nat) (id : Nat) :
    openTabs (openTabs tabs id) id = openTabs tabs id := by
  apply focusing_existing_preserves_slots
  by_cases h : id ∈ tabs <;> simp [openTabs, h]

theorem session_selections_preserve_unique (tabs selections : List Nat)
    (hu : tabs.Nodup) : (selections.foldl openTabs tabs).Nodup := by
  induction selections generalizing tabs with
  | nil => exact hu
  | cons id rest ih => exact ih (openTabs tabs id) (opening_preserves_unique tabs id hu)

end Nano.TabNavModel
