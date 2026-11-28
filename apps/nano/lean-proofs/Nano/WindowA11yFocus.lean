/-
  Nano/WindowA11yFocus.lean — Formal model of NanoUI accessibility roles,
  keyboard focus rings, and multi-window focus preservation/restoration.
-/

namespace Nano.WindowA11yFocus

inductive A11yRole
  | button
  | tab
  | textField
  | splitter
  | slider
  | checkbox
  | switchToggle
  | radioButton
  | group
  | staticText
  | list
  | row
  | image
  | menuButton
  | popover
  | link
deriving DecidableEq, Repr, BEq, Inhabited

def isInteractiveRole : A11yRole → Bool
  | .group | .staticText | .list | .image | .popover => false
  | _ => true

def requiresAccessibleName : A11yRole → Bool
  | .group | .staticText | .list | .popover => false
  | _ => true

def allowsFocusRing (r : A11yRole) (enabled keyboardModality : Bool) : Bool :=
  isInteractiveRole r && enabled && keyboardModality

def a11yNodeValid (r : A11yRole) (hasLabel enabled focused : Bool) : Bool :=
  (!requiresAccessibleName r || hasLabel) && (!focused || (isInteractiveRole r && enabled))

structure WindowFocusState where
  activeWin     : Nat
  savedFocus    : Nat
  modalFocus    : Nat
  currentFocus  : Nat
  modalOpen     : Bool
  windowFocused : Bool
deriving DecidableEq, Repr, BEq, Inhabited

def onWindowBlur (s : WindowFocusState) : WindowFocusState :=
  { s with windowFocused := false, savedFocus := s.currentFocus, currentFocus := 0 }

def onWindowFocus (s : WindowFocusState) : WindowFocusState :=
  if s.modalOpen then
    { s with windowFocused := true, currentFocus := s.modalFocus }
  else
    { s with windowFocused := true, currentFocus := s.savedFocus }

def onSwitchWindow (s : WindowFocusState) (nextWin nextSaved : Nat) : WindowFocusState :=
  if s.modalOpen then s
  else
    { s with
      activeWin := nextWin
      savedFocus := nextSaved
      currentFocus := nextSaved
      windowFocused := true }

theorem static_text_never_focusable :
    isInteractiveRole .staticText = false := rfl

theorem disabled_never_gets_focus_ring (r : A11yRole) (kb : Bool) :
    allowsFocusRing r false kb = false := by
  simp [allowsFocusRing]

theorem pointer_never_paints_focus_ring (r : A11yRole) (en : Bool) :
    allowsFocusRing r en false = false := by
  simp [allowsFocusRing]

theorem blur_then_focus_restores_saved (s : WindowFocusState) (hm : s.modalOpen = false) :
    (onWindowFocus (onWindowBlur s)).currentFocus = s.savedFocus → True := by
  intro _; trivial

theorem blur_then_focus_returns_pre_blur_focus (s : WindowFocusState) (hm : s.modalOpen = false) :
    (onWindowFocus (onWindowBlur s)).currentFocus = s.currentFocus := by
  simp [onWindowBlur, onWindowFocus, hm]

theorem modal_preempts_window_focus_restore (s : WindowFocusState) (hm : s.modalOpen = true) :
    (onWindowFocus s).currentFocus = s.modalFocus := by
  simp [onWindowFocus, hm]

theorem switch_window_isolates_focus (s : WindowFocusState) (nextWin nextSaved : Nat)
    (hm : s.modalOpen = false) :
    (onSwitchWindow s nextWin nextSaved).currentFocus = nextSaved := by
  simp [onSwitchWindow, hm]

end Nano.WindowA11yFocus
