#!/usr/bin/env bash
# Run a heavy build or test command in a first-come-first-served queue shared
# by every process on this machine: scripts/heavy-build.sh cargo test -p harness-ui --lib
# Several agents can work in parallel worktrees; only their builds queue.
#
#   HARNESS_HEAVY_BUILD_LANE=<name>     an independent queue (default: one shared lane)
#   HARNESS_HEAVY_BUILD_SLOTS=<n>       jobs the lane runs at once (default 1)
#   HARNESS_HEAVY_BUILD_LOCK=<path>     an explicit lock path; takes precedence over the lane
#   HARNESS_HEAVY_BUILD_WARN_AFTER=<s>  waiters report a holder past this many seconds,
#                                       once per that many seconds (default 900; 0 = never)
#   scripts/heavy-build.sh --status [lane or lock path]...
#
# A lane is a lock path. Slot 1 is the lock directory itself, as before, so an
# older copy of this script still excludes and is excluded; slot n > 1 is
# "<lock>.slot<n>". A slot holds pid, since and cmd. Waiters queue as tickets
# "<lock>.queue/<sequence>.<pid>", numbered under a short mutex, and a waiter
# may take a free slot only when fewer live tickets are ahead of it than there
# are free slots. A ticket or slot whose pid has exited is stale.
#
# The queue is bookkeeping and never stops a build. If the queue, its mutex,
# a ticket or a slot n > 1 cannot be created or written, that call warns once
# on stderr and falls back to the old behaviour: it takes slot 1 (the lock
# directory) when free, in no particular order, still excluding every holder.

set -uo pipefail
shopt -s nullglob

base="${TMPDIR:-/tmp}"
base="${base%/}"

die() {
  echo "heavy-build: $*" >&2
  exit 2
}

lane_lock() {
  case "$1" in
    '' | default) lock_path="$base/harness-heavy-build.lock" ;;
    *[!A-Za-z0-9_-]*) die "lane names use letters, digits, '-' and '_': $1" ;;
    *) lock_path="$base/harness-heavy-build.$1.lock" ;;
  esac
}

lane_label() {
  case "$1" in
    "$base/harness-heavy-build.lock") label=default ;;
    "$base"/harness-heavy-build.*.lock)
      label="${1#"$base"/harness-heavy-build.}"
      label="${label%.lock}"
      ;;
    *) label="$1" ;;
  esac
}

is_number() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
}

# Like the engine's check, another user's live process (EPERM) counts as alive.
alive() {
  is_number "$1" && { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }
}

# A queue path that exists but cannot hold the queue.
queue_unusable() {
  [[ -e "$1" || -L "$1" ]] && ! [[ -d "$1" && -w "$1" && -x "$1" ]]
}

# make_dir <path>: 0 if this call created it, 1 if it is a directory someone
# else holds, 2 if it cannot be created. A holder may release it between the
# failed mkdir and the check, so only repeated failures count as 2.
make_dir() {
  local _
  for _ in 1 2 3; do
    mkdir "$1" 2>/dev/null && return 0
    [[ -d "$1" ]] && return 1
  done
  return 2
}

read_line() { # read_line <var> <file>: the file's first line, or empty
  local _line=""
  { IFS= read -r _line <"$2"; } 2>/dev/null
  printf -v "$1" '%s' "$_line"
}

# The pid in a ticket name "<sequence>.<zero-padded pid>".
ticket_pid() {
  tpid="${1##*/}"
  tpid="${tpid#*.}"
  tpid="${tpid#"${tpid%%[!0]*}"}"
}

duration() {
  local s=$1
  if ((s >= 3600)); then
    printf -v dur '%dh%02dm%02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
  elif ((s >= 60)); then
    printf -v dur '%dm%02ds' $((s / 60)) $((s % 60))
  else
    dur="${s}s"
  fi
}

# Unix seconds without a fork per poll.
epoch_base="$(date +%s)"
epoch_offset=$SECONDS
now() {
  epoch=$((epoch_base + SECONDS - epoch_offset))
}

# Prints one lane, removing stale holders and tickets as it reads.
print_lane() {
  local lock=$1 slot ticket pid since cmd rows="" holding=0 queued=0
  now
  for slot in "$lock" "$lock".slot*; do
    [[ -d "$slot" ]] || continue
    read_line pid "$slot/pid"
    if [[ -n "$pid" ]] && ! alive "$pid"; then
      rm -rf "$slot"
      continue
    fi
    read_line since "$slot/since"
    read_line cmd "$slot/cmd"
    dur="?"
    is_number "$since" && duration $((epoch - since))
    holding=$((holding + 1))
    rows+="  holding pid ${pid:-?} for $dur: $cmd"$'\n'
  done
  for ticket in "$lock.queue"/*; do
    ticket_pid "$ticket"
    if ! alive "$tpid"; then
      rm -f "$ticket"
      continue
    fi
    since="" cmd=""
    { IFS= read -r since && IFS= read -r cmd; } 2>/dev/null <"$ticket"
    dur="?"
    is_number "$since" && duration $((epoch - since))
    queued=$((queued + 1))
    rows+="  queued #$queued pid $tpid for $dur: $cmd"$'\n'
  done
  # A queued holder creates the queue first and nothing removes it, so a
  # holder without one runs without it (or is an older copy of this script).
  if queue_unusable "$lock.queue" || { ((holding > 0)) && [[ ! -e "$lock.queue" ]]; }; then
    rows+="  queue unavailable at $lock.queue; builds run without it"$'\n'
  fi
  lane_label "$lock"
  if ((holding + queued == 0)); then
    echo "lane $label: idle"
  else
    echo "lane $label: $holding holding, $queued queued"
  fi
  printf '%s' "$rows"
}

status() {
  local locks=() path arg known
  if (($# > 0)); then
    for arg in "$@"; do
      case "$arg" in
        */*) locks+=("$arg") ;;
        *) lane_lock "$arg" && locks+=("$lock_path") ;;
      esac
    done
  elif [[ -n "${HARNESS_HEAVY_BUILD_LOCK:-}" ]]; then
    locks=("$HARNESS_HEAVY_BUILD_LOCK")
  elif [[ -n "${HARNESS_HEAVY_BUILD_LANE:-}" ]]; then
    lane_lock "$HARNESS_HEAVY_BUILD_LANE"
    locks=("$lock_path")
  else
    lane_lock default
    locks=("$lock_path")
    for path in "$base"/harness-heavy-build.*; do
      path="${path%.queue}"
      path="${path%.slot*}"
      case "$path" in
        "$base"/harness-heavy-build.*.lock) ;;
        *) continue ;;
      esac
      for known in "${locks[@]}"; do
        [[ "$known" == "$path" ]] && continue 2
      done
      locks+=("$path")
    done
  fi
  for path in "${locks[@]}"; do
    print_lane "$path"
  done
}

if [[ "${1:-}" == --status ]]; then
  shift
  status "$@"
  exit 0
fi
(($# > 0)) || die "usage: heavy-build.sh <command> [args...] | --status [lane]..."

if [[ -n "${HARNESS_HEAVY_BUILD_LOCK:-}" ]]; then
  lock="$HARNESS_HEAVY_BUILD_LOCK"
else
  lane_lock "${HARNESS_HEAVY_BUILD_LANE:-}"
  lock="$lock_path"
fi
slots="${HARNESS_HEAVY_BUILD_SLOTS:-1}"
if ! is_number "$slots" || ((10#$slots < 1)); then
  die "HARNESS_HEAVY_BUILD_SLOTS must be a positive integer: $slots"
fi
slots=$((10#$slots))
warn_after="${HARNESS_HEAVY_BUILD_WARN_AFTER:-900}"
if ! is_number "$warn_after"; then
  # Reporting is optional; a bad value must not stop the build.
  echo "heavy-build: ignoring HARNESS_HEAVY_BUILD_WARN_AFTER=$warn_after (not whole seconds)" >&2
  warn_after=900
fi
warn_after=$((10#$warn_after))
queue="$lock.queue"

# A command started by a holder of this lane runs at once. OWNER is the
# innermost holder, as before; OWNERS lists every enclosing one, so a nested
# call back into an outer lane does not wait for itself.
for owner in ${HARNESS_HEAVY_BUILD_OWNER:-} ${HARNESS_HEAVY_BUILD_OWNERS:-}; do
  alive "$owner" || continue
  for held in "$lock" "$lock".slot*; do
    read_line pid "$held/pid"
    if [[ "$pid" == "$owner" ]]; then
      exec "$@"
    fi
  done
done

# The engine supplies a per-run directory; marker names are wrapper PIDs and
# contents are Unix seconds of the first failed attempt, not the last poll.
wait_marker=""
slot=""
ticket=""
ticket_tmp=""
mutex_owned=false
poll_pid=""
cleanup() {
  if [[ -n "$poll_pid" ]]; then
    kill "$poll_pid" 2>/dev/null || true
    wait "$poll_pid" 2>/dev/null || true
  fi
  leave_queue
  if [[ -n "$wait_marker" ]]; then
    rm -f "$wait_marker"
  fi
  # In particular, a cancelled waiter must never remove the active owner's
  # lock: only a slot this process took, and still holds, is released.
  if [[ -n "$slot" ]]; then
    read_line pid "$slot/pid"
    if [[ -z "$pid" || "$pid" == "$$" ]]; then
      rm -rf "$slot"
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# One line, truncated, for status and notices.
cmdline="$*"
cmdline="${cmdline//$'\n'/ }"
if ((${#cmdline} > 160)); then
  cmdline="${cmdline:0:157}..."
fi

# Releases whatever this process has in the queue; errors are ignored.
leave_queue() {
  if "$mutex_owned"; then
    rm -rf "$queue/.mutex" 2>/dev/null
    mutex_owned=false
  fi
  if [[ -n "$ticket_tmp" ]]; then
    rm -f "$ticket_tmp" 2>/dev/null
    ticket_tmp=""
  fi
  if [[ -n "$ticket" ]]; then
    rm -f "$ticket" 2>/dev/null
    ticket=""
  fi
}

# Takes the next ticket, or fails if the queue cannot be used. The mutex makes
# "one more than the last ticket" and creating it one step; it is held for a
# directory listing and a rename.
enqueue() {
  local holder last=0 name spins=0 clear_failures=0
  mkdir -p "$queue" 2>/dev/null
  [[ -d "$queue" ]] || return 1
  while :; do
    make_dir "$queue/.mutex"
    case $? in
      0) break ;;
      2) return 1 ;;
    esac
    read_line holder "$queue/.mutex/pid"
    if [[ -n "$holder" ]]; then
      spins=0
      if ! alive "$holder"; then
        # Another waiter may clear it at the same moment; only repeated
        # failures mean it cannot be removed.
        rm -rf "$queue/.mutex" 2>/dev/null || ((++clear_failures < 3)) || return 1
        continue
      fi
    else
      # Its taker died between creating it and naming itself (about 5 s).
      spins=$((spins + 1))
      if ((spins > 100)); then
        rm -rf "$queue/.mutex" 2>/dev/null || ((++clear_failures < 3)) || return 1
        spins=0
        continue
      fi
    fi
    sleep 0.05
  done
  mutex_owned=true
  if { echo $$ >"$queue/.mutex/pid"; } 2>/dev/null; then
    for name in "$queue"/*; do
      name="${name##*/}"
      name="${name%%.*}"
      is_number "$name" && last=$((10#$name))
    done
    now
    ticket_tmp="$queue/.ticket.$$"
    printf -v name '%012d.%010d' $((last + 1)) $$
    if { printf '%s\n%s\n' "$epoch" "$cmdline" >"$ticket_tmp"; } 2>/dev/null &&
      mv -f "$ticket_tmp" "$queue/$name" 2>/dev/null; then
      ticket="$queue/$name"
      ticket_tmp=""
    fi
  fi
  rm -rf "$queue/.mutex" 2>/dev/null
  mutex_owned=false
  [[ -n "$ticket" ]] || { leave_queue; return 1; }
}

# Sets ahead to the live tickets before ours, removing dead ones on the way.
# Returns 1 if ours is gone, 2 if it exists but the queue cannot be listed.
queue_position() {
  local t
  ahead=0
  [[ -n "$ticket" ]] || return 1
  for t in "$queue"/*; do
    if [[ "$t" == "$ticket" ]]; then
      return 0
    fi
    ticket_pid "$t"
    if alive "$tpid"; then
      ahead=$((ahead + 1))
    else
      rm -f "$t" 2>/dev/null
    fi
  done
  [[ -e "$ticket" ]] && return 2
  return 1
}

# Leaves the queue for the rest of this call: slot 1 only, as before the queue.
queued=true
fall_back() {
  leave_queue
  queued=false
  slots=1
  echo "heavy-build: queue unavailable at $queue; running this build without it" >&2
}

# Sets free_slots to the lane's free slot paths, clearing exited holders.
find_free_slots() {
  local i s pid
  free_slots=()
  for ((i = 1; i <= slots; i++)); do
    s="$lock"
    ((i > 1)) && s="$lock.slot$i"
    if [[ -d "$s" ]]; then
      read_line pid "$s/pid"
      [[ -n "$pid" ]] && ! alive "$pid" && rm -rf "$s" 2>/dev/null
    fi
    [[ -d "$s" ]] || free_slots+=("$s")
  done
}

# Waiters name a long holder once per interval; nothing is killed.
last_notice=""
report_long_holds() {
  local s pid since cmd printed=false
  ((warn_after > 0)) || return 0
  now
  if [[ -n "$last_notice" ]] && ((epoch - last_notice < warn_after)); then
    return 0
  fi
  for s in "$lock" "$lock".slot*; do
    read_line pid "$s/pid"
    read_line since "$s/since"
    if ! alive "$pid" || ! is_number "$since" || ((epoch - since < warn_after)); then
      continue
    fi
    read_line cmd "$s/cmd"
    duration $((epoch - since))
    lane_label "$lock"
    echo "heavy-build: pid $pid has held a slot in lane $label for $dur: $cmd" >&2
    printed=true
  done
  if "$printed"; then
    last_notice=$epoch
  fi
}

enqueue || fall_back
while :; do
  if "$queued"; then
    queue_position
    case $? in
      1) enqueue || fall_back ;;
      2) fall_back ;;
      *)
        if ((ahead < slots)); then
          # Only waiters that could be served touch the slots.
          find_free_slots
          if ((ahead < ${#free_slots[@]})); then
            for s in "${free_slots[@]}"; do
              make_dir "$s"
              case $? in
                0) slot="$s" && break ;;
                2) [[ "$s" == "$lock" ]] || { fall_back && break; } ;;
              esac
            done
            [[ -n "$slot" ]] && break
          fi
        fi
        ;;
    esac
  fi
  if ! "$queued"; then
    # As before the queue: slot 1 when free, clearing a holder that has exited.
    find_free_slots
    if ((${#free_slots[@]} > 0)) && mkdir "$lock" 2>/dev/null; then
      slot="$lock"
      break
    fi
  fi
  if [[ -z "$wait_marker" && -n "${HARNESS_BUILD_WAIT_DIR:-}" ]]; then
    wait_marker="$HARNESS_BUILD_WAIT_DIR/$$"
    # Optional status reporting must not prevent the command from running.
    # Only the engine creates this directory; do not resurrect a retired run.
    (date +%s >"$wait_marker") 2>/dev/null || true
  fi
  report_long_holds
  # Override only for synthetic tests. Background sleep makes queued signal
  # handling prompt even with the normal five-second polling interval.
  sleep "${HARNESS_HEAVY_BUILD_POLL_INTERVAL:-5}" &
  poll_pid=$!
  wait "$poll_pid"
  poll_pid=""
done
# A slot is ours once created; what it records is for status and stale checks.
{
  echo $$ >"$slot/pid"
  now
  echo "$epoch" >"$slot/since"
  printf '%s\n' "$cmdline" >"$slot/cmd"
} 2>/dev/null
leave_queue
if [[ -n "$wait_marker" ]]; then
  rm -f "$wait_marker"
  wait_marker=""
fi
export HARNESS_HEAVY_BUILD_OWNER="$$"
export HARNESS_HEAVY_BUILD_OWNERS="${HARNESS_HEAVY_BUILD_OWNERS:+$HARNESS_HEAVY_BUILD_OWNERS }$$"
"$@"
