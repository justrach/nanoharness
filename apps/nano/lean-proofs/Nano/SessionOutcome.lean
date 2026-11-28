/- Models the persisted status gate shared by workspace.markOf,
   display_status, and chatIndicator, and the network-loss handling in
   SessionStatusWindow.resolvedIndicator. Unread is orthogonal to liveness. -/

namespace Nano.SessionOutcome

inductive Status where
  | idle | working | awaitingInput | errored
deriving DecidableEq

inductive Mark where
  | idle | completed | working | awaitingInput | errored
deriving DecidableEq

def effective (age : Int) (row : Option Status) : Option Status :=
  match row with
  | some .working | some .awaitingInput => if age > 45000 then none else row
  | _ => row

def indicator (unseen offline : Bool) (status : Option Status) : Mark :=
  match status with
  | none => .idle
  | some .working => if offline then .idle else .working
  | some .awaitingInput => .awaitingInput
  | some .errored => if unseen then .errored else .idle
  | some .idle => if unseen then .completed else .idle

theorem completed_requires_settled_unseen (unseen offline : Bool)
    (status : Option Status) :
    indicator unseen offline status = .completed ↔
      status = some .idle ∧ unseen = true := by
  cases status with
  | none => simp [indicator]
  | some s => cases s <;> cases unseen <;> cases offline <;> simp [indicator]

theorem missing_status_is_neutral (unseen offline : Bool) :
    indicator unseen offline none = .idle := rfl

theorem stale_active_is_neutral (unseen offline : Bool) (age : Int)
    (h : age > 45000) (s : Status) (active : s = .working ∨ s = .awaitingInput) :
    indicator unseen offline (effective age (some s)) = .idle := by
  rcases active with rfl | rfl <;> simp [effective, h, indicator]

theorem unseen_failure_survives_liveness_loss (age : Int) (offline : Bool) :
    indicator true offline (effective age (some .errored)) = .errored := rfl

/- Local registry status can supply a saved outcome after a restart. A live
   session watch still takes precedence over its own earlier registry row. -/
def localPersisted (completed : Bool) (status : Status) : Option Status :=
  match status with
  | .errored => some .errored
  | .idle => if completed then some .idle else none
  | .working | .awaitingInput => none

def regain (live : Option Status) (completed : Bool) (saved : Status) : Option Status :=
  live.or (localPersisted completed saved)

theorem active_requires_live_after_restart (completed : Bool) (saved : Status) :
    regain none completed saved ≠ some .working ∧
    regain none completed saved ≠ some .awaitingInput := by
  cases completed <;> cases saved <;> simp [regain, localPersisted, Option.or]

theorem live_overrides_saved (now saved : Status) (completed : Bool) :
    regain (some now) completed saved = some now := rfl

end Nano.SessionOutcome
