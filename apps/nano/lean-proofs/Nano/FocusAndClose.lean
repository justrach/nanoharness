/-
  Nano/FocusAndClose.lean — Single text-focus owner, Cmd+W target resolution,
  and split-pane active focus border cues.
-/

namespace Nano.FocusAndClose

inductive TextFocusOwner
  | none
  | modalField
  | paletteInput
  | sidebarSearch
  | writeEditor
  | designNote
  | browseUrl
  | composer
deriving DecidableEq, Repr, BEq, Inhabited

def activeTextOwner
    (hasModal paletteOpen sidebarSearchFocus writeOpen designNoteFocused browseUrlFocused hasChatArea : Bool) :
    TextFocusOwner :=
  if hasModal then .modalField
  else if paletteOpen then .paletteInput
  else if sidebarSearchFocus then .sidebarSearch
  else if writeOpen then .writeEditor
  else if designNoteFocused then .designNote
  else if browseUrlFocused then .browseUrl
  else if hasChatArea then .composer
  else .none

inductive SurfaceFocus
  | chat
  | host
  | designCanvas
  | files
deriving DecidableEq, Repr, BEq, Inhabited

inductive CloseDecision
  | noop
  | askArchiveChoice
  | confirmArchiveChoice
  | closeHostTab
  | closeDesignCanvas
  | closeFiles
  | closePaneTab
  | closeSplitPane
  | closeWorkspaceTab
deriving DecidableEq, Repr, BEq, Inhabited

def decideClose
    (surface : SurfaceFocus)
    (closeChoiceOpen : Bool)
    (groupTabs splitPanes : Nat)
    (hostBgOpen expanded isOnlyNewChat needsAsk : Bool) : CloseDecision :=
  if closeChoiceOpen then .confirmArchiveChoice
  else match surface with
    | .host => .closeHostTab
    | .designCanvas => .closeDesignCanvas
    | .files => .closeFiles
    | .chat =>
      if groupTabs > 1 then .closePaneTab
      else if splitPanes > 1 then .closeSplitPane
      else if !expanded && hostBgOpen then .closeHostTab
      else if isOnlyNewChat then .noop
      else if needsAsk then .askArchiveChoice
      else .closeWorkspaceTab

/-- Focus border alpha in percent (0..100) for split pane separation. -/
def splitPaneBorderPct (splitCount : Nat) (isFocused : Bool) : Nat :=
  if splitCount <= 1 then 0
  else if isFocused then 100
  else 28

theorem modal_preempts_composer_focus
    (hasModal paletteOpen sidebarSearchFocus writeOpen designNoteFocused browseUrlFocused hasChatArea : Bool)
    (h : hasModal = true ∨ paletteOpen = true) :
    activeTextOwner hasModal paletteOpen sidebarSearchFocus writeOpen designNoteFocused browseUrlFocused hasChatArea ≠ .composer := by
  rcases h with h | h <;> simp [activeTextOwner, h] <;> split <;> simp

theorem resting_chat_gives_composer_focus (hasChatArea : Bool) (h : hasChatArea = true) :
    activeTextOwner false false false false false false hasChatArea = .composer := by
  simp [activeTextOwner, h]

theorem only_new_chat_never_closes_window :
    decideClose .chat false 1 1 false false true true = .noop ∧
    decideClose .chat false 1 1 false false true false = .noop := by
  decide

theorem host_surface_never_archives_chat
    (gt sp : Nat) (hb ex ic na : Bool) :
    decideClose .host false gt sp hb ex ic na = .closeHostTab := by
  rfl

theorem design_surface_closes_design_canvas
    (gt sp : Nat) (hb ex ic na : Bool) :
    decideClose .designCanvas false gt sp hb ex ic na = .closeDesignCanvas := by
  rfl

theorem files_surface_never_archives_chat
    (gt sp : Nat) (hb ex ic na : Bool) :
    decideClose .files false gt sp hb ex ic na = .closeFiles := by
  rfl

theorem expanded_chat_closes_before_hidden_host (gt sp : Nat) (hgt : gt <= 1) (hsp : sp <= 1) :
    decideClose .chat false gt sp true true false false = .closeWorkspaceTab := by
  have h1 : ¬(gt > 1) := by omega
  have h2 : ¬(sp > 1) := by omega
  simp [decideClose, h1, h2]

theorem split_focus_strictly_brighter (n : Nat) (hn : n >= 2) :
    splitPaneBorderPct n false < splitPaneBorderPct n true := by
  unfold splitPaneBorderPct
  have hnot : ¬(n <= 1) := by omega
  simp [hnot]

end Nano.FocusAndClose
