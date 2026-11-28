/-
  Nano/BrowseConnect.lean — Formal model of `justrach/browse` Connected Apps
  (`v1-p256-sig`) routing, loopback/origin guards, replay bounds, and pairing FSM.
-/

namespace Nano.BrowseConnect

inductive UrlScheme
  | graffView
  | http
  | https
  | other
deriving DecidableEq, Repr, BEq, Inhabited

inductive BrowserRoute
  | localSavedView
  | externalBrowse
deriving DecidableEq, Repr, BEq, Inhabited

/-- Public web URLs (`http`, `https`, `other`) ALWAYS route to `justrach/browse`.
    Only sandboxed internal `graff-view://` artifacts use local WKWebView. -/
def routeUrl : UrlScheme → BrowserRoute
  | .graffView => .localSavedView
  | .http | .https | .other => .externalBrowse

inductive HostKind
  | loopbackPort
  | otherHost
deriving DecidableEq, Repr, BEq, Inhabited

/-- Localhost Connected Apps server refuses non-loopback `Host` and any `Origin` header (`403 bad_origin`). -/
def loopbackRequestAllowed (host : HostKind) (hasOriginHeader : Bool) : Bool :=
  (host == .loopbackPort) && !hasOriginHeader

/-- Nonce replay + timestamp skew guard (120-second window). -/
def nonceAccepted (seenBefore : Bool) (skewSec : Nat) : Bool :=
  !seenBefore && skewSec <= 120

/-- Pairing 6-digit decimal confirmation code from first 4 BE bytes of SHA-256. -/
def pairingCode (be32 : Nat) : Nat :=
  be32 % 1000000

inductive ConnState
  | needsBrowseInstall
  | waitingBrowseLaunch
  | discovered
  | pairingPending
  | connected
  | pairDenied
  | tokenExpired
deriving DecidableEq, Repr, BEq, Inhabited

inductive ConnEvent
  | detectedNotInstalled
  | binaryFoundClosed
  | connectJsonRead
  | pairRequested
  | userApproved
  | userDenied
  | tokenTimedOut
  | appClosed
  | revoked
deriving DecidableEq, Repr, BEq, Inhabited

def mcpCallsPermitted : ConnState → Bool
  | .connected => true
  | _ => false

/-- Live viewport frame polling runs strictly when connected, visible, idle, and >= 750ms since last frame. -/
def shouldPollFrame (st : ConnState) (tabVisible : Bool) (elapsedMs : Nat) (inFlight : Bool) : Bool :=
  match st with
  | .connected => tabVisible && !inFlight && decide (elapsedMs >= 750)
  | _ => false

def nextConnState (cur : ConnState) (ev : ConnEvent) : ConnState :=
  match ev with
  | .detectedNotInstalled => .needsBrowseInstall
  | .binaryFoundClosed    => .waitingBrowseLaunch
  | .connectJsonRead      => .discovered
  | .pairRequested        => if cur == .discovered then .pairingPending else cur
  | .userApproved         => if cur == .pairingPending then .connected else cur
  | .userDenied           => .pairDenied
  | .tokenTimedOut        => .tokenExpired
  | .appClosed            => .waitingBrowseLaunch
  | .revoked              => .pairDenied

theorem http_https_never_use_local_webview (s : UrlScheme)
    (h : s = .http ∨ s = .https) :
    routeUrl s = .externalBrowse := by
  rcases h with h | h <;> simp [h, routeUrl]

theorem graff_view_stays_local :
    routeUrl .graffView = .localSavedView := by
  rfl

theorem origin_header_always_rejected (h : HostKind) :
    loopbackRequestAllowed h true = false := by
  cases h <;> rfl

theorem non_loopback_always_rejected (hasOrig : Bool) :
    loopbackRequestAllowed .otherHost hasOrig = false := by
  rfl

theorem mcp_requires_connected (s : ConnState) (h : mcpCallsPermitted s = true) :
    s = .connected := by
  cases s <;> simp_all [mcpCallsPermitted]

theorem disconnect_or_revoke_revokes_mcp (s : ConnState) (ev : ConnEvent)
    (h : ev = .appClosed ∨ ev = .revoked ∨ ev = .userDenied ∨ ev = .tokenTimedOut) :
    mcpCallsPermitted (nextConnState s ev) = false := by
  rcases h with h | h | h | h <;> subst h <;> rfl

theorem pairing_code_strictly_6_digits (be32 : Nat) :
    pairingCode be32 < 1000000 := by
  unfold pairingCode
  exact Nat.mod_lt be32 (by decide)

theorem expired_timestamp_rejected (seen : Bool) (skewSec : Nat) (h : skewSec > 120) :
    nonceAccepted seen skewSec = false := by
  unfold nonceAccepted
  have hle : ¬(skewSec <= 120) := by omega
  simp [hle]

theorem poll_requires_connected_and_visible (st : ConnState) (vis : Bool) (elapsed : Nat) (inflight : Bool)
    (h : shouldPollFrame st vis elapsed inflight = true) :
    st = .connected ∧ vis = true ∧ inflight = false := by
  cases st <;> simp_all [shouldPollFrame, Bool.and_eq_true]

theorem poll_respects_750ms_debounce (st : ConnState) (vis : Bool) (elapsed : Nat) (inflight : Bool)
    (h : elapsed < 750) :
    shouldPollFrame st vis elapsed inflight = false := by
  cases st <;> simp [shouldPollFrame, Bool.and_eq_true]
  omega

end Nano.BrowseConnect
