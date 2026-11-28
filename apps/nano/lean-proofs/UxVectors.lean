import Nano.FrameSchedule
import Nano.OverlayMutex
import Nano.EscapeTermination
import Nano.HoverStability
import Nano.FocusAndClose
import Nano.TabNavModel
import Nano.KeymapPartition
import Nano.UiMode3
import Nano.DesignCanvas
import Nano.BrowseConnect
import Nano.WindowA11yFocus

open Nano.FrameSchedule
open Nano.OverlayMutex
open Nano.EscapeTermination
open Nano.HoverStability
open Nano.FocusAndClose
open Nano.TabNavModel
open Nano.KeymapPartition
open Nano.UiMode3
open Nano.DesignCanvas
open Nano.BrowseConnect
open Nano.WindowA11yFocus

private def b2u (b : Bool) : String := if b then "1" else "0"

private def emitFooter : IO Unit := do
  for sw in [0, 30, 47, 48, 79, 80, 155, 156, 200, 259, 260, 344, 380, 500] do
    let l := sessionFooterLayout sw
    IO.println s!"footer,{sw},{l.pad},{b2u l.showCheckout},{l.checkoutTextMax},{b2u l.showBranch},{l.branchTextMax},{b2u l.showActions}"

private def emitOverlay : IO Unit := do
  let idx (k : OverlayKind) : Nat := match k with
    | .none => 0 | .sessionSearch => 1 | .contextPinned => 2 | .agentWorkPinned => 3
    | .accountUsageOpen => 4 | .starMenu => 5 | .updatesPopover => 6 | .actionMenu => 7
    | .filterMenu => 8 | .moreMenu => 9 | .spaceMenu => 10 | .checkoutMenu => 11
    | .refMenu => 12 | .chatMenu => 13 | .linkMenu => 14 | .stripMenu => 15
    | .accountMenu => 16 | .modelPicker => 17 | .customTheme => 18 | .themeImport => 19
    | .closeChoice => 20 | .settingsRecording => 21 | .actionCommandReview => 22
    | .commandPalette => 23 | .openChooser => 24 | .projectSetup => 25 | .setup => 26
  let sample := [OverlayKind.none, .accountMenu, .filterMenu, .stripMenu, .customTheme, .closeChoice, .commandPalette, .openChooser, .setup]
  for cur in sample do
    for nxt in sample do
      let res := openOverlay cur nxt
      let tog := toggleOverlay cur nxt
      IO.println s!"overlay,{idx cur},{idx nxt},{idx res},{idx tog},{tier res},{activeLayer res},{b2u (scrimActive res)},{b2u (keepsKeyboard res)}"

private def emitEscape : IO Unit := do
  let actId (a : EscAction) : Nat := match a with
    | .noop => 0 | .dismissSetup => 1 | .dismissProjectSetup => 2 | .dismissOpenChooser => 3
    | .dismissPalette => 4 | .dismissPicker => 5 | .cancelRecording => 6 | .dismissCloseChoice => 7
    | .dismissDialog => 8 | .dismissPopupMenu => 9 | .dismissImagePreview => 10 | .closeWrite => 11
    | .cancelQueueEdit => 12 | .wizardStepBack => 13 | .closeCompletion => 14 | .closeSettings => 15
    | .interruptAgent => 16
  let cases : List EscState :=
    [ {}
    , { setupOpen := true, paletteOpen := true, agentBusy := true }
    , { projectSetupOpen := true, popupMenuOpen := true }
    , { openChooserOpen := true, settingsOpen := true }
    , { paletteOpen := true, popupMenuOpen := true, agentBusy := true }
    , { pickerOpen := true, settingsOpen := true }
    , { settingsRecording := true, settingsOpen := true }
    , { closeChoiceOpen := true, agentBusy := true }
    , { dialogOpen := true, popupMenuOpen := true }
    , { popupMenuOpen := true, wizardCanBack := true, agentBusy := true }
    , { imagePreviewOpen := true, agentBusy := true }
    , { writeOpen := true, settingsOpen := true }
    , { queueEditOpen := true, composerCompletionOpen := true, agentBusy := true }
    , { wizardCanBack := true, composerCompletionOpen := true, agentBusy := true }
    , { composerCompletionOpen := true, agentBusy := true }
    , { settingsOpen := true, agentBusy := true }
    , { agentBusy := true }
    ]
  for (s, i) in cases.zipIdx do
    let a := escAction s
    let nxt := stepEsc s
    IO.println s!"escape,{i},{actId a},{escWeight s},{escWeight nxt},{b2u (restoresComposer a)}"

private def emitHover : IO Unit := do
  for cw in [12, 32, 40, 71, 72, 120, 220] do
    for act in [false, true] do
      for hov in [false, true] do
        for cc in [false, true] do
          let res := tabControlsReserve cw act cc
          let lw := tabLabelWidth cw act hov cc
          let op := tabCloseGlyphOpacityPct act hov cc
          IO.println s!"hover,{cw},{b2u act},{b2u hov},{b2u cc},{res},{lw},{op}"

private def emitClose : IO Unit := do
  let sId (s : SurfaceFocus) : Nat := match s with | .chat => 0 | .host => 1 | .designCanvas => 2 | .files => 3
  let dId (d : CloseDecision) : Nat := match d with
    | .noop => 0 | .askArchiveChoice => 1 | .confirmArchiveChoice => 2 | .closeHostTab => 3
    | .closeDesignCanvas => 4 | .closeFiles => 5 | .closePaneTab => 6 | .closeSplitPane => 7
    | .closeWorkspaceTab => 8
  for sf in [SurfaceFocus.chat, .host, .designCanvas, .files] do
    for cc in [false, true] do
      for gt in [1, 2] do
        for sp in [1, 2] do
          for hb in [false, true] do
            for ex in [false, true] do
              for ic in [false, true] do
                for na in [false, true] do
                  let d := decideClose sf cc gt sp hb ex ic na
                  IO.println s!"close,{sId sf},{b2u cc},{gt},{sp},{b2u hb},{b2u ex},{b2u ic},{b2u na},{dId d}"

private def emitTabCycle : IO Unit := do
  for tot in [0, 1, 2, 3, 5] do
    for cur in [0, 1, 2, 4] do
      for fwd in [false, true] do
        IO.println s!"tabcycle,{tot},{cur},{b2u fwd},{stepFlatTab tot cur fwd}"

private def emitMode3 : IO Unit := do
  let mId (m : Nano.UiMode3.UiMode) : Nat := match m with | .zen => 0 | .developer => 1 | .design => 2
  for m in [Nano.UiMode3.UiMode.zen, .developer, .design] do
    let p := profileOf m
    for settingsOpen in [false, true] do
      IO.println s!"mode3,{mId m},{b2u settingsOpen},{b2u p.showsWorkspaceTree},{b2u p.showsMultiAxisFilters},{b2u p.showsRowTechBadges},{b2u p.showsGitCheckoutChrome},{b2u p.showsPromptRail},{b2u p.showsActionToolbar},{b2u p.showsGroupedSections},{b2u p.showsDevTrailingToggles},{b2u p.showsDesignCanvasToggle},{b2u p.showsZenNewSessionBox},{b2u p.suppressesPromos},{p.composerCornerRadius},{p.trailingButtonCount},{trailingReservePx m settingsOpen},{mId (nextMode m)}"
    for avail in [296, 376, 420, 936] do
      for lastSlot in [214, 240, 468] do
        for so in [false, true] do
          IO.println s!"mode3_resp,{mId m},{b2u so},{avail},{lastSlot},{effectiveTrailingCount m so avail lastSlot},{effectiveTrailingReservePx m so avail lastSlot}"

private def emitDesign : IO Unit := do
  for z in [10, 25, 80, 100, 150, 400, 999] do
    IO.println s!"design_zoom,{z},{clampZoomPct z},{stepZoomPct z true},{stepZoomPct z false}"
  for outer in [16, 12, 8] do
    for border in [0, 1, 2] do
      for pad in [0, 2, 4, 8] do
        IO.println s!"design_radius,{outer},{border},{pad},{concentricInner outer border pad}"
  for (lA, lB) in [(0, 10000), (500, 8000), (2000, 6000), (4000, 4500)] do
    IO.println s!"design_contrast,{lA},{lB},{contrastRatioX100 lA lB},{b2u (meetsWcagAA lA lB false)},{b2u (meetsWcagAA lA lB true)}"

private def emitBrowse : IO Unit := do
  let scId (s : UrlScheme) : Nat := match s with | .graffView => 0 | .http => 1 | .https => 2 | .other => 3
  let rtId (r : BrowserRoute) : Nat := match r with | .localSavedView => 0 | .externalBrowse => 1
  for s in [UrlScheme.graffView, .http, .https, .other] do
    IO.println s!"browse_route,{scId s},{rtId (routeUrl s)}"
  for be in [0, 999999, 1000000, 1234567, 4294967295] do
    IO.println s!"browse_code,{be},{pairingCode be}"
  for seen in [false, true] do
    for skew in [0, 60, 120, 121] do
      IO.println s!"browse_nonce,{b2u seen},{skew},{b2u (nonceAccepted seen skew)}"
  let stId (st : ConnState) : Nat := match st with
    | .needsBrowseInstall => 0 | .waitingBrowseLaunch => 1 | .discovered => 2
    | .pairingPending => 3 | .connected => 4 | .pairDenied => 5 | .tokenExpired => 6
  for st in [ConnState.waitingBrowseLaunch, .pairingPending, .connected, .tokenExpired] do
    for vis in [false, true] do
      for elapsed in [0, 749, 750, 1500] do
        for inf in [false, true] do
          IO.println s!"browse_poll,{stId st},{b2u vis},{elapsed},{b2u inf},{b2u (shouldPollFrame st vis elapsed inf)}"

private def emitWindowA11y : IO Unit := do
  let rId (r : A11yRole) : Nat := match r with
    | .button => 0 | .tab => 1 | .textField => 2 | .splitter => 3
    | .slider => 4 | .checkbox => 5 | .switchToggle => 6 | .radioButton => 7
    | .group => 8 | .staticText => 9 | .list => 10 | .row => 11
    | .image => 12 | .menuButton => 13 | .popover => 14 | .link => 15
  let roles : List A11yRole := [.button, .textField, .group, .staticText, .image, .popover, .link]
  for r in roles do
    for lbl in [false, true] do
      for en in [false, true] do
        for foc in [false, true] do
          for kb in [false, true] do
            IO.println s!"a11y,{rId r},{b2u lbl},{b2u en},{b2u foc},{b2u kb},{b2u (isInteractiveRole r)},{b2u (requiresAccessibleName r)},{b2u (allowsFocusRing r en kb)},{b2u (a11yNodeValid r lbl en foc)}"
  for modalOpen in [false, true] do
    for cur in [10, 42] do
      for modalId in [99] do
        let st : WindowFocusState := { activeWin := 1, savedFocus := cur, modalFocus := modalId, currentFocus := cur, modalOpen := modalOpen, windowFocused := true }
        let after := onWindowFocus (onWindowBlur st)
        let sw := onSwitchWindow st 2 77
        IO.println s!"winfocus,{b2u modalOpen},{cur},{modalId},{after.currentFocus},{sw.activeWin},{sw.currentFocus}"

def main : IO Unit := do
  emitFooter
  emitOverlay
  emitEscape
  emitHover
  emitClose
  emitTabCycle
  emitMode3
  emitDesign
  emitBrowse
  emitWindowA11y
