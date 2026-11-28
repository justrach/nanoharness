/-
  Nano/EscapeTermination.lean — Ordered Escape peel-off and termination proofs.

  Every Escape key press handles at most the single highest-priority active
  overlay or mode and strictly decreases `escWeight`. Higher modal tiers
  never leak Escape to background controls or accidental agent interrupt.
-/

namespace Nano.EscapeTermination

inductive EscAction
  | noop
  | dismissSetup
  | dismissProjectSetup
  | dismissOpenChooser
  | dismissPalette
  | dismissPicker
  | cancelRecording
  | dismissCloseChoice
  | dismissDialog
  | dismissPopupMenu
  | dismissImagePreview
  | closeWrite
  | cancelQueueEdit
  | wizardStepBack
  | closeCompletion
  | closeSettings
  | interruptAgent
deriving DecidableEq, Repr, BEq, Inhabited

structure EscState where
  setupOpen : Bool := false
  projectSetupOpen : Bool := false
  openChooserOpen : Bool := false
  paletteOpen : Bool := false
  pickerOpen : Bool := false
  settingsRecording : Bool := false
  closeChoiceOpen : Bool := false
  dialogOpen : Bool := false
  popupMenuOpen : Bool := false
  imagePreviewOpen : Bool := false
  writeOpen : Bool := false
  queueEditOpen : Bool := false
  wizardCanBack : Bool := false
  composerCompletionOpen : Bool := false
  settingsOpen : Bool := false
  agentBusy : Bool := false
deriving DecidableEq, Repr, BEq, Inhabited

private def b2n (b : Bool) : Nat := if b then 1 else 0

def escWeight (s : EscState) : Nat :=
  b2n s.setupOpen + b2n s.projectSetupOpen + b2n s.openChooserOpen +
  b2n s.paletteOpen + b2n s.pickerOpen + b2n s.settingsRecording +
  b2n s.closeChoiceOpen + b2n s.dialogOpen + b2n s.popupMenuOpen +
  b2n s.imagePreviewOpen + b2n s.writeOpen + b2n s.queueEditOpen +
  b2n s.wizardCanBack + b2n s.composerCompletionOpen + b2n s.settingsOpen +
  b2n s.agentBusy

def escAction (s : EscState) : EscAction :=
  if s.setupOpen then .dismissSetup
  else if s.projectSetupOpen then .dismissProjectSetup
  else if s.openChooserOpen then .dismissOpenChooser
  else if s.paletteOpen then .dismissPalette
  else if s.pickerOpen then .dismissPicker
  else if s.settingsRecording then .cancelRecording
  else if s.closeChoiceOpen then .dismissCloseChoice
  else if s.dialogOpen then .dismissDialog
  else if s.popupMenuOpen then .dismissPopupMenu
  else if s.imagePreviewOpen then .dismissImagePreview
  else if s.writeOpen then .closeWrite
  else if s.queueEditOpen then .cancelQueueEdit
  else if s.wizardCanBack then .wizardStepBack
  else if s.composerCompletionOpen then .closeCompletion
  else if s.settingsOpen then .closeSettings
  else if s.agentBusy then .interruptAgent
  else .noop

def stepEsc (s : EscState) : EscState :=
  if s.setupOpen then { s with setupOpen := false }
  else if s.projectSetupOpen then { s with projectSetupOpen := false }
  else if s.openChooserOpen then { s with openChooserOpen := false }
  else if s.paletteOpen then { s with paletteOpen := false }
  else if s.pickerOpen then { s with pickerOpen := false }
  else if s.settingsRecording then { s with settingsRecording := false }
  else if s.closeChoiceOpen then { s with closeChoiceOpen := false }
  else if s.dialogOpen then { s with dialogOpen := false }
  else if s.popupMenuOpen then { s with popupMenuOpen := false }
  else if s.imagePreviewOpen then { s with imagePreviewOpen := false }
  else if s.writeOpen then { s with writeOpen := false }
  else if s.queueEditOpen then { s with queueEditOpen := false }
  else if s.wizardCanBack then { s with wizardCanBack := false }
  else if s.composerCompletionOpen then { s with composerCompletionOpen := false }
  else if s.settingsOpen then { s with settingsOpen := false }
  else if s.agentBusy then { s with agentBusy := false }
  else s

def restoresComposer : EscAction → Bool
  | .dismissProjectSetup | .dismissOpenChooser | .dismissPalette
  | .dismissPicker | .dismissCloseChoice | .dismissDialog
  | .dismissPopupMenu | .closeWrite | .cancelQueueEdit
  | .closeCompletion | .closeSettings => true
  | _ => false

theorem stepEsc_strictly_decreases (s : EscState) (h : escAction s ≠ .noop) :
    escWeight (stepEsc s) < escWeight s := by
  by_cases h1 : s.setupOpen
  · simp [stepEsc, escWeight, b2n, h1]
  · by_cases h2 : s.projectSetupOpen
    · simp [stepEsc, escWeight, b2n, h1, h2]
    · by_cases h3 : s.openChooserOpen
      · simp [stepEsc, escWeight, b2n, h1, h2, h3]
      · by_cases h4 : s.paletteOpen
        · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4]
        · by_cases h5 : s.pickerOpen
          · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5]
          · by_cases h6 : s.settingsRecording
            · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6]
            · by_cases h7 : s.closeChoiceOpen
              · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7]
              · by_cases h8 : s.dialogOpen
                · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7, h8]
                · by_cases h9 : s.popupMenuOpen
                  · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7, h8, h9]
                  · by_cases h10 : s.imagePreviewOpen
                    · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10]
                    · by_cases h11 : s.writeOpen
                      · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11]
                      · by_cases h12 : s.queueEditOpen
                        · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12]
                        · by_cases h13 : s.wizardCanBack
                          · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13]
                          · by_cases h14 : s.composerCompletionOpen
                            · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14]
                            · by_cases h15 : s.settingsOpen
                              · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15]
                              · by_cases h16 : s.agentBusy
                                · simp [stepEsc, escWeight, b2n, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16]
                                · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16] at h

theorem esc_idempotent_at_rest (s : EscState) (h : escAction s = .noop) :
    stepEsc s = s := by
  by_cases h1 : s.setupOpen
  · simp [escAction, h1] at h
  by_cases h2 : s.projectSetupOpen
  · simp [escAction, h1, h2] at h
  by_cases h3 : s.openChooserOpen
  · simp [escAction, h1, h2, h3] at h
  by_cases h4 : s.paletteOpen
  · simp [escAction, h1, h2, h3, h4] at h
  by_cases h5 : s.pickerOpen
  · simp [escAction, h1, h2, h3, h4, h5] at h
  by_cases h6 : s.settingsRecording
  · simp [escAction, h1, h2, h3, h4, h5, h6] at h
  by_cases h7 : s.closeChoiceOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7] at h
  by_cases h8 : s.dialogOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8] at h
  by_cases h9 : s.popupMenuOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9] at h
  by_cases h10 : s.imagePreviewOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10] at h
  by_cases h11 : s.writeOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11] at h
  by_cases h12 : s.queueEditOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12] at h
  by_cases h13 : s.wizardCanBack
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13] at h
  by_cases h14 : s.composerCompletionOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14] at h
  by_cases h15 : s.settingsOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15] at h
  by_cases h16 : s.agentBusy
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16] at h
  simp [stepEsc, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16]

theorem modal_blocks_agent_interrupt (s : EscState)
    (h : s.setupOpen = true ∨ s.paletteOpen = true ∨ s.popupMenuOpen = true ∨ s.imagePreviewOpen = true) :
    escAction s ≠ .interruptAgent := by
  by_cases h1 : s.setupOpen
  · simp [escAction, h1]
  by_cases h2 : s.projectSetupOpen
  · simp [escAction, h1, h2]
  by_cases h3 : s.openChooserOpen
  · simp [escAction, h1, h2, h3]
  by_cases h4 : s.paletteOpen
  · simp [escAction, h1, h2, h3, h4]
  by_cases h5 : s.pickerOpen
  · simp [escAction, h1, h2, h3, h4, h5]
  by_cases h6 : s.settingsRecording
  · simp [escAction, h1, h2, h3, h4, h5, h6]
  by_cases h7 : s.closeChoiceOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7]
  by_cases h8 : s.dialogOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8]
  by_cases h9 : s.popupMenuOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9]
  rcases h with hs | hp | hm | hi
  · contradiction
  · contradiction
  · contradiction
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h9, hi]

theorem popup_blocks_wizard_back (s : EscState) (h : s.popupMenuOpen = true) :
    escAction s ≠ .wizardStepBack := by
  by_cases h1 : s.setupOpen
  · simp [escAction, h1]
  by_cases h2 : s.projectSetupOpen
  · simp [escAction, h1, h2]
  by_cases h3 : s.openChooserOpen
  · simp [escAction, h1, h2, h3]
  by_cases h4 : s.paletteOpen
  · simp [escAction, h1, h2, h3, h4]
  by_cases h5 : s.pickerOpen
  · simp [escAction, h1, h2, h3, h4, h5]
  by_cases h6 : s.settingsRecording
  · simp [escAction, h1, h2, h3, h4, h5, h6]
  by_cases h7 : s.closeChoiceOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7]
  by_cases h8 : s.dialogOpen
  · simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8]
  simp [escAction, h1, h2, h3, h4, h5, h6, h7, h8, h]

end Nano.EscapeTermination
