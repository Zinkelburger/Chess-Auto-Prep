#!/usr/bin/env bash
# Install (or check) the systemd containment that stops one runaway process
# from taking every agent session on the machine down with it.
#
#   scripts/oom_containment.sh          install / repair, then report
#   scripts/oom_containment.sh --check  report only, exit 1 if not in place
#
# ---------------------------------------------------------------------------
# Why this exists
#
# 2026-09-04, 12:32:36. A mutation harness mutated `_COLOR_SEARCH_WINDOW = 4`
# to `10**9` in a module under test. The test file *imports that constant* and
# sizes a list with it:
#
#     bottom = [_state(f"b{i}", ...) for i in range(_COLOR_SEARCH_WINDOW)]
#
# so the child test process asked for a billion objects — 582 GB at the
# measured 624 bytes each. It reached 30 GB in 162 s and the kernel OOM-killed
# it. That part worked as designed.
#
# What did not work: systemd's default `OOMPolicy=stop` means one OOM-killed
# process makes systemd tear down the WHOLE scope. It stopped app-code-5711
# .scope — VS Code, every Claude Code session in it, their subagents and 11
# stockfish processes. Seven agent sessions died; none was the culprit.
#
# Three settings, three different failures:
#
#   OOMPolicy=continue   an OOM kill takes the runaway, not the session that
#                        launched it. This is the one that mattered most.
#   MemoryMax (scope)    one runaway hits a ceiling in its own cgroup, where
#                        the cgroup OOM killer picks it (it is by far the
#                        largest task there) instead of the machine racing to
#                        a *global* OOM, which picks from every process alive.
#   MemoryMax (slice)    the sum of all app scopes is bounded too, so several
#                        merely-large apps cannot add up to the same global OOM.
#
# This covers ad-hoc scripts an agent writes and backgrounds, which is what
# actually happened — `scripts/ci.sh`'s own cap only covers what goes through
# `ci.sh`.
# ---------------------------------------------------------------------------
set -uo pipefail

# ---------------------------------------------------------------------------
# Sizing — measured, not guessed
#
# `memory.max` counts anon + page cache, and the kernel reclaims cache before
# it kills anything, so the number that matters is ANON: real, unreclaimable
# memory. Measured under a deliberately heavy load (~6 concurrent agent
# sessions plus a running mutation campaign):
#
#   app-code-….scope   3.71 G anon   ← a VS Code window running all 6 sessions
#   Chromium           2.19 G anon   (its 15.7 G "peak" is page cache)
#   firefox            2.01 G anon
#   app.slice TOTAL   11.98 G anon
#   user.slice        13.19 G anon   ← mongod; genuinely resident, not cache
#   session.slice      0.57 G anon
#   background.slice   0.38 G anon
#
# And from the 2026-09-04 OOM task dump: with the 29.8 G runaway excluded, the
# entire machine's legitimate anon was ~17 G, and no single legitimate process
# exceeded 1.02 G.
#
# So the caps below are roughly 2-3x the heaviest thing ever legitimately
# measured, not 6-8x. The Sep-4 runaway would now die at 10 G instead of 30 G.
#
# They also sum to 52G on a 62 GB machine (24+20+4+4), which — unlike the
# earlier, looser set — means the total is structurally bounded below RAM. A
# global OOM caused by user processes is no longer reachable by arithmetic, so
# the root-level ceiling this script used to ask for is no longer needed.
# ---------------------------------------------------------------------------
SCOPE_MAX=${CHESS_PREP_SCOPE_MAX:-10G}      # one app scope: 2.7x the 3.71 G measured
SLICE_MAX=${CHESS_PREP_SLICE_MAX:-24G}      # all app scopes: 2x the 11.98 G measured
CONTAINER_MAX=${CHESS_PREP_CONTAINER_MAX:-20G}  # mongod really does hold 13.19 G
AUX_MAX=${CHESS_PREP_AUX_MAX:-4G}           # session/background: ~7x their 0.5 G
UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mBAD\033[0m   %s\n' "$*"; }

if ! command -v systemctl >/dev/null 2>&1; then
  echo "no systemd here — nothing to install (this is a Linux-desktop guard)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight: would any cap land below what a unit has actually needed?
#
# This check exists because skipping it broke something. A type-wide 10G scope
# default, sized from app-scope measurements, was applied to every scope —
# including the podman scope holding mongod at 13.2 G, which the kernel then
# OOM-killed. The measurement that would have caught it was already in hand.
# Never widen a default without sweeping what it will newly apply to.
# ---------------------------------------------------------------------------
preflight() {
  local base="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service"
  local risky=0 d mx an
  while read -r d; do
    [[ -f "$d/memory.stat" ]] || continue
    an=$(awk '/^anon /{print $2}' "$d/memory.stat" 2>/dev/null) || continue
    [[ "$an" =~ ^[0-9]+$ ]] || continue
    # What cap would this unit get? Read what it has now; after an install this
    # reflects the new value, so run it before AND after.
    mx=$(cat "$d/memory.max" 2>/dev/null)
    [[ "$mx" =~ ^[0-9]+$ ]] || continue
    if (( an > mx * 85 / 100 )); then
      risky=1
      printf '  \033[31mBAD\033[0m   %s holds %.1fG unreclaimable against a %.0fG cap — it will be OOM-killed\n' \
        "$(basename "$d" | cut -c1-40)" "$(echo "$an/1073741824" | bc -l)" "$(echo "$mx/1073741824" | bc -l)"
    fi
  done < <(find "$base" -type d 2>/dev/null)
  return $risky
}

if [[ $CHECK -eq 0 ]]; then
  mkdir -p "$UD/app-.scope.d" "$UD/app.slice.d" "$UD/scope.d" "$UD/slice.d"
  # Type-wide defaults FIRST. Capping only `app-*` scopes left two holes an
  # agent can fall into without trying: a scope created under any other name
  # (`systemd-run --unit=whatever`) came out unbounded, and
  # `systemd-run --slice=anything.slice` created an entirely uncapped slice.
  # These apply to every scope and every slice; the specific drop-ins below
  # reuse the same FILENAME, which is how systemd masks a general drop-in with
  # a more specific one rather than having them fight.
  cat > "$UD/scope.d/50-oom-containment.conf" <<EOF
# Managed by scripts/oom_containment.sh — default for EVERY user scope.
[Scope]
OOMPolicy=continue
MemoryMax=$SCOPE_MAX
EOF
  cat > "$UD/slice.d/50-oom-containment.conf" <<EOF
# Managed by scripts/oom_containment.sh — default for EVERY user slice.
[Slice]
MemoryMax=$AUX_MAX
EOF
  # app-.scope.d applies to every `app-*.scope`: editors, terminals, and so
  # every agent session running inside one.
  cat > "$UD/app-.scope.d/50-oom-containment.conf" <<EOF
# Managed by scripts/oom_containment.sh — see that file for the incident.
[Scope]
OOMPolicy=continue
MemoryMax=$SCOPE_MAX
EOF
  cat > "$UD/app.slice.d/50-oom-containment.conf" <<EOF
# Managed by scripts/oom_containment.sh — see that file for the incident.
[Slice]
MemoryMax=$SLICE_MAX
EOF
  # Slices OUTSIDE app.slice, which the app-scope caps do not reach. The
  # nested user.slice is where podman containers land — the lila dev stack's
  # mongod sits there at ~16 G and was completely uncapped, which an
  # opening-explorer import can grow without bound.
  for pair in "user.slice:$CONTAINER_MAX" "session.slice:$AUX_MAX" "background.slice:$AUX_MAX"; do
    sl=${pair%%:*}; mx=${pair##*:}
    mkdir -p "$UD/$sl.d"
    cat > "$UD/$sl.d/50-oom-containment.conf" <<EOF
# Managed by scripts/oom_containment.sh — outside app.slice, capped separately.
[Slice]
MemoryMax=$mx
EOF
  done
  # Podman container scopes sit inside the nested user.slice, so the generic
  # scope default lands on them too — and on 2026-09-04 13:37:24 a 10G default
  # sized from app-scope measurements killed mongod, which legitimately holds
  # 13.2 G. Containers are bounded by user.slice instead.
  mkdir -p "$UD/libpod-.scope.d"
  cat > "$UD/libpod-.scope.d/50-oom-containment.conf" <<EOF
# Managed by scripts/oom_containment.sh — containers are bounded by user.slice.
[Scope]
OOMPolicy=continue
MemoryMax=$CONTAINER_MAX
EOF

  # ci.sh sets its own per-invocation cap with `systemd-run -p`. Drop-ins
  # OVERRIDE a transient unit's -p properties, so the generic scope.d default
  # silently replaced it — CHESS_PREP_MEM_MAX looked effective and did nothing.
  # This masks the generic file for ci.sh's scopes only (same filename = mask)
  # and deliberately sets no MemoryMax, handing control back to ci.sh.
  mkdir -p "$UD/chess-prep-ci-.scope.d"
  cat > "$UD/chess-prep-ci-.scope.d/50-oom-containment.conf" <<EOF
# Managed by scripts/oom_containment.sh — no MemoryMax on purpose; ci.sh sets it.
[Scope]
OOMPolicy=continue
EOF

  # NOT settable from here: the root of the user manager's own delegated
  # subtree (-.slice / user@.service). systemd accepts the drop-in and the
  # kernel ignores it, so we do not write one — a limit that reports as
  # configured but is not enforced is worse than none. See the footer.
  systemctl --user daemon-reload 2>/dev/null
fi

rc=0
# Check what the KERNEL applied. systemd will happily report a MemoryMax it
# could not actually set (it does exactly that for -.slice), so reading its
# config back proves nothing.
BASE=/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service
for sl in app.slice user.slice session.slice background.slice; do
  [[ -d "$BASE/$sl" ]] || continue
  kern=$(cat "$BASE/$sl/memory.max" 2>/dev/null)
  if [[ "$kern" =~ ^[0-9]+$ ]]; then
    ok "$sl capped at $((kern / 1073741824))G (kernel-enforced)"
  else
    bad "$sl is UNCAPPED — a runaway there is bounded only by total RAM"; rc=1
  fi
done

scopes=0; unguarded=0
while read -r u; do
  [[ -z "$u" ]] && continue
  scopes=$((scopes + 1))
  pol=$(systemctl --user show "$u" -p OOMPolicy --value 2>/dev/null)
  mm=$(systemctl --user show "$u" -p MemoryMax --value 2>/dev/null)
  if [[ "$pol" != "continue" || ! "$mm" =~ ^[0-9]+$ ]]; then
    unguarded=$((unguarded + 1))
    [[ $CHECK -eq 1 ]] && bad "$u: OOMPolicy=$pol MemoryMax=$mm"
  fi
done < <(systemctl --user list-units --type=scope --no-legend 2>/dev/null | awk '{print $1}' | grep '^app-')

if [[ $unguarded -eq 0 ]]; then
  ok "$scopes running app scope(s): OOMPolicy=continue, capped at $SCOPE_MAX each"
else
  bad "$unguarded of $scopes app scope(s) unguarded — an OOM kill there stops the whole scope"; rc=1
fi

# Does an arbitrary NEW scope actually come out capped? This is the check that
# matters: everything above describes units that already exist, but the failure
# mode is a script an agent starts later, under a name nobody predicted.
if preflight; then
  ok "no unit is capped below its own unreclaimable working set"
else
  bad "a cap is set below what that unit actually needs — raise it before it is killed"; rc=1
fi

fresh=$(systemd-run --user --scope --quiet --unit "oomcheck-$$-$RANDOM.scope" -- \
  cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/oomcheck-$$-*.scope/memory.max 2>/dev/null | head -1)
if [[ "$fresh" =~ ^[0-9]+$ ]]; then
  ok "a newly created scope inherits a $((fresh / 1073741824))G cap by default"
else
  # Fall back to reading it from inside the scope, which is what actually matters.
  fresh=$(systemd-run --user --scope --quiet --unit "oomcheck2-$$-$RANDOM.scope" -- \
    bash -c 'cat /sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max' 2>/dev/null | tail -1)
  if [[ "$fresh" =~ ^[0-9]+$ ]]; then
    ok "a newly created scope inherits a $((fresh / 1073741824))G cap by default"
  else
    bad "a newly created scope comes out UNCAPPED — the type-wide drop-in is missing"; rc=1
  fi
fi

# What this does and does not guarantee
#
# DOES: nothing an agent starts can escape by accident. cgroup membership is
# inherited on every fork, so fork/setsid/nohup/disown all stay inside the cap
# (verified), and the type-wide scope.d/slice.d defaults mean a scope or slice
# created under any name is capped too. There is no step to remember and no
# convention to follow — this is why it holds where "always use ci.sh" did not:
# the script that caused the 2026-09-04 incident simply did not call ci.sh.
#
# DOES NOT: resist deliberate circumvention. Everything under user@.service is
# user-owned, so an agent running as you can `echo max > .../memory.max`,
# `systemctl --user set-property … MemoryMax=infinity`, or edit these very
# drop-ins. Measured ownership:
#
#   …/app.slice/app-code-….scope   memory.max  owned by the user  → raisable
#   …/app.slice                    memory.max  owned by the user  → raisable
#   …/user@….service               memory.max  owned by ROOT      → not raisable
#   …/user-….slice                 memory.max  owned by ROOT      → not raisable
#
# So the only ceiling an agent cannot lift is one set on user-.slice by the
# SYSTEM systemd instance. The caps here already sum to 52G on 62 GB of RAM, so
# this is not needed for the arithmetic — it is the tamper-resistant backstop:
#
#   sudo mkdir -p /etc/systemd/system/user-.slice.d
#   printf '[Slice]\\nMemoryMax=54G\\n' | \\
#     sudo tee /etc/systemd/system/user-.slice.d/50-oom-containment.conf
#   sudo systemctl daemon-reload
#
# Worth doing, but it is a system-wide change and not this script's to make.
exit $rc
