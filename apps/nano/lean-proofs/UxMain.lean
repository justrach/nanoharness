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

def main : IO Unit := do
  -- Sanity runtime checks alongside Kernel theorems
  assert! (sessionFooterLayout 380).showActions == true
  assert! (sessionFooterLayout 40).showBranch == false
  assert! (toggleOverlay (toggleOverlay .none .accountMenu) .accountMenu == .none)
  assert! (openOverlay .commandPalette .accountMenu == .commandPalette)
  assert! (defaultsPairwiseDisjoint == true)
  assert! (every_default_valid_to_bind_check)
  assert! (routeUrl .https == .externalBrowse)
  assert! (routeUrl .graffView == .localSavedView)
  assert! (pairingCode 1234567 == 234567)
  assert! (isInteractiveRole .staticText == false)
  assert! (shouldPollFrame .connected true 750 false == true)
  assert! (shouldPollFrame .connected true 500 false == false)
  IO.println "All 11 Nano UX Lean 4 kernel modules verified."
where
  every_default_valid_to_bind_check : Bool :=
    defaultRebindableChords.all (fun p => canBindShortcut p.2 p.1 defaultRebindableChords)
