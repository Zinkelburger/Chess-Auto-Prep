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
# Sizing — measured, not guessed, and re-measured after the first numbers bit
#
# `memory.max` counts anon + page cache. The kernel reclaims cache before it
# kills anything, so a cap that is near the working set does not kill: it
# THRASHES. Every page of the Flutter SDK, the editor and the browser gets
# evicted and re-faulted in a loop, the cgroup's PSI climbs, anon spills into
# zram until it is full, and then systemd-oomd — which watches pressure, not
# size — reads the stall as an emergency and kills the biggest cgroup under
# it. That is precisely what the first version of these caps did, on the
# afternoon of 2026-09-04:
#
#   app.slice      MemoryMax=24G   sat AT its cap all afternoon: memory.events
#                                  counted 7,031,265 cap hits, swap (8G zram)
#                                  reached 100%, and at 16:33 systemd-oomd
#                                  killed the whole VS Code scope for "memory
#                                  pressure on app.slice 85% > 80% for 20s".
#                                  Six agent sessions died. Free RAM at the
#                                  time: 29 GB.
#   app-code scope MemoryMax=10G   hit by the editor scope between 14:43 and
#                                  15:02: the kernel killed five dart
#                                  frontend_servers, a `claude` session and
#                                  the running app inside it, one by one.
#
# So the caps have one job — bound a RUNAWAY — and must sit well clear of what
# the desktop legitimately uses, which is more than the first measurement
# (one moment, 11.98 G anon) suggested:
#
#   app.slice     13.3 G anon + 9.5 G file at the time it was pinned; a full
#                 `flutter test --coverage` peaks at 4.4 G (its own scope),
#                 the driver's app at 2.9 G, VS Code with six agent sessions
#                 at 5 G, the two Chromium apps at 2-3.4 G each.
#   an app scope  VS Code + six sessions + their MCP servers: 5 G idle,
#                 8.5 G when they are all building.
#
# The caps below are ~3x those. They no longer sum to less than RAM
# (48+20+4+4 = 76 G on 62 G) and that is deliberate: the sum-below-RAM idea
# was what made 24G look safe, and file cache made it a thrash budget instead.
# A runaway still dies alone at its own scope's cap (16 G for an app, 8 G for
# a ci.sh job) long before the machine is short; the slice cap is only there
# so app.slice as a whole cannot reach a GLOBAL oom on its own.
# ---------------------------------------------------------------------------
SCOPE_MAX=${CHESS_PREP_SCOPE_MAX:-16G}      # one app scope: ~2x the 8.5 G VS Code+6 sessions reached
SLICE_MAX=${CHESS_PREP_SLICE_MAX:-48G}      # all app scopes: 2x the 24 G it was pinned at; 77% of RAM
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
