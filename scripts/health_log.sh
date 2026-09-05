#!/usr/bin/env bash
# scripts/health_log.sh — leave a trail of what this machine was doing, so a
# freeze or a dead editor can be explained after the fact instead of guessed at.
#
#   scripts/health_log.sh install        # a systemd --user timer appends one line
#                                        # every 30s to ~/.local/state/chess-prep/health.log
#   scripts/health_log.sh uninstall
#   scripts/health_log.sh status         # is the timer running, where is the log
#   scripts/health_log.sh sample         # one line, now (what the timer runs)
#   scripts/health_log.sh tail [N]       # the last N samples (default 20)
#   scripts/health_log.sh report [SINCE] # what happened: kills, heavy jobs and
#                                        # the samples where the machine was
#                                        # struggling, one timeline. SINCE is a
#                                        # journalctl time ("2 hours ago", "17:00").
#
# Why: on 2026-09-04 the desktop froze for minutes and VS Code was killed
# twice, and nothing on the machine had recorded why. Reconstructing it took
# an hour of journalctl and cgroup archaeology. The answer, for the record:
# two full `flutter test --coverage` runs (11 workers each, ~22 threads) were
# running at once because one bypassed the shared lock; three Wine prefixes
# left half-initialised in the morning had been burning a core each for seven
# hours; and app.slice had been pinned at its own 24G MemoryMax all afternoon,
# swapping to a full zram, until systemd-oomd read the resulting pressure as
# an emergency and killed the editor scope. `report` would have shown all of
# that in one screen.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE_DIR=${CHESS_PREP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/chess-prep}
LOG="$STATE_DIR/health.log"
UNIT=chess-prep-health
UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CG="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service"
INTERVAL=${CHESS_PREP_HEALTH_INTERVAL:-30s}
ROTATE_BYTES=$((8 * 1024 * 1024))

gib() { awk -v b="${1:-0}" 'BEGIN { if (b == "max" || b == "") printf "inf"; else printf "%.1f", b / 1073741824 }'; }

# One line. Everything here is a file read or one `ps`, so it costs nothing
# worth measuring even every 30s.
sample() {
  local ts load ncpu avail swap_total swap_free swap_pct
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  load=$(cut -d' ' -f1 /proc/loadavg)
  ncpu=$(nproc)
  avail=$(awk '/^MemAvailable/ {print $2 * 1024}' /proc/meminfo)
  swap_total=$(awk '/^SwapTotal/ {print $2}' /proc/meminfo)
  swap_free=$(awk '/^SwapFree/ {print $2}' /proc/meminfo)
  swap_pct=$(awk -v t="$swap_total" -v f="$swap_free" 'BEGIN { if (t > 0) printf "%d", (t - f) * 100 / t; else printf "0" }')
  # PSI: "some" = at least one task stalled, "full" = every task stalled, i.e.
  # the freeze itself. avg10 is the ten-second window.
  psi() { awk -v k="$1" '$1 == k { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) { sub("avg10=", "", $i); printf "%s", $i } }' "/proc/pressure/$2" 2>/dev/null; }
  local mem_some mem_full cpu_some io_full
  mem_some=$(psi some memory); mem_full=$(psi full memory)
  cpu_some=$(psi some cpu);    io_full=$(psi full io)

  local slice_cur slice_max code_cur code_max ci_cur ci_n
  slice_cur=$(cat "$CG/app.slice/memory.current" 2>/dev/null || echo 0)
  slice_max=$(cat "$CG/app.slice/memory.max" 2>/dev/null || echo max)
  code_cur=0; code_max=max
  for d in "$CG"/app.slice/app-code-*.scope; do
    [[ -d $d ]] || continue
    code_cur=$((code_cur + $(cat "$d/memory.current" 2>/dev/null || echo 0)))
    code_max=$(cat "$d/memory.max" 2>/dev/null || echo max)
  done
  ci_cur=0; ci_n=0
  for d in "$CG"/app.slice/chess-prep-*.scope; do
    [[ -d $d ]] || continue
    ci_n=$((ci_n + 1))
    ci_cur=$((ci_cur + $(cat "$d/memory.current" 2>/dev/null || echo 0)))
  done

  # Who is actually burning CPU. flutter_tester counts the test workers, the
  # thing that turns one `flutter test` into 22 runnable threads.
  local top testers
  top=$(ps -eo pcpu,comm --no-headers --sort=-pcpu 2>/dev/null | awk 'NR <= 3 && $1 >= 5 { printf "%s%s:%d", (n++ ? "," : ""), $2, $1 }')
  testers=$(pgrep -c -x flutter_tester 2>/dev/null); testers=${testers:-0}

  printf '%s load=%s/%s avail=%sG swap=%s%% psi_mem=%s/%s psi_cpu=%s psi_io=%s app.slice=%s/%sG code=%s/%sG ci=%s:%sG testers=%s top=%s\n' \
    "$ts" "$load" "$ncpu" "$(gib "$avail")" "$swap_pct" \
    "${mem_some:-?}" "${mem_full:-?}" "${cpu_some:-?}" "${io_full:-?}" \
    "$(gib "$slice_cur")" "$(gib "$slice_max")" "$(gib "$code_cur")" "$(gib "$code_max")" \
    "$ci_n" "$(gib "$ci_cur")" "$testers" "${top:-idle}"
}

record() {
  mkdir -p "$STATE_DIR"
  if [[ -f $LOG ]] && (( $(stat -c %s "$LOG") > ROTATE_BYTES )); then
    mv -f "$LOG" "$LOG.1"
  fi
  sample >> "$LOG"
}

install_timer() {
  command -v systemctl >/dev/null 2>&1 || { echo "no systemd here; run '$0 sample' from cron instead"; exit 0; }
  mkdir -p "$UD" "$STATE_DIR"
  cat > "$UD/$UNIT.service" <<UNIT
# Managed by scripts/health_log.sh — one health sample, appended to $LOG.
[Unit]
Description=Chess Auto Prep machine-health sample

[Service]
Type=oneshot
ExecStart=$ROOT/scripts/health_log.sh sample --record
# Tiny, and kept out of app.slice so it keeps sampling while app.slice is the
# thing in trouble.
Slice=background.slice
MemoryMax=64M
Nice=10
UNIT
  cat > "$UD/$UNIT.timer" <<UNIT
# Managed by scripts/health_log.sh
[Unit]
Description=Sample machine health for Chess Auto Prep every $INTERVAL

[Timer]
OnBootSec=1min
OnUnitActiveSec=$INTERVAL
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer" >/dev/null 2>&1
  systemctl --user start "$UNIT.service" 2>/dev/null || true
  status
}

uninstall_timer() {
  systemctl --user disable --now "$UNIT.timer" >/dev/null 2>&1 || true
  rm -f "$UD/$UNIT.service" "$UD/$UNIT.timer"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "timer removed; $LOG kept"
}

status() {
  if systemctl --user is-active --quiet "$UNIT.timer" 2>/dev/null; then
    local n last
    n=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    last=$(tail -n 1 "$LOG" 2>/dev/null | cut -d' ' -f1)
    echo "health timer running every $INTERVAL → $LOG ($n samples, last ${last:-none})"
    return 0
  fi
  echo "health timer NOT installed — scripts/health_log.sh install"
  return 1
}

# The timeline. journalctl for the kills and the heavy scopes, the log for
# the samples, merged and sorted; samples are only shown where the machine was
# actually struggling, or the report would be nothing but samples.
report() {
  local since=${1:-6 hours ago}
  python3 - "$LOG" "$since" "$(nproc)" <<'PY'
import datetime as dt, re, subprocess, sys
log, since, ncpu = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = []

def journal(*args):
    try:
        out = subprocess.run(["journalctl", "--no-pager", "-o", "short-iso", "--since", since, *args],
                             capture_output=True, text=True, timeout=60).stdout
    except Exception as e:
        return []
    return out.splitlines()

def ts_of(line):
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", line)
    return m.group(1) if m else None

# Kernel cgroup OOM kills: which cgroup hit its cap, and which process died.
for line in journal("-k"):
    t = ts_of(line)
    if not t: continue
    m = re.search(r"oom_memcg=(\S+?),task_memcg=\S+?,task=([^,]+),pid=(\d+)", line)
    if m:
        cg = m.group(1).split("/")[-1]
        rows.append((t, "KILL ", f"kernel: {cg} hit its MemoryMax → killed {m.group(2)} (pid {m.group(3)})"))
    elif "Out of memory: Killed process" in line:
        rows.append((t, "KILL ", "kernel: GLOBAL out of memory → " + line.split("kernel: ")[-1][:120]))

# systemd-oomd: kills a whole cgroup for sustained pressure or full swap.
for line in journal("-u", "systemd-oomd"):
    t = ts_of(line)
    if t and "Killed " in line:
        m = re.search(r"Killed (\S+) due to (.+)$", line)
        if m:
            rows.append((t, "KILL ", f"systemd-oomd killed {m.group(1).split('/')[-1]} — {m.group(2)[:110]}"))

# The user manager: editor scope deaths, and every heavy scope with its peak.
for line in journal("--user"):
    t = ts_of(line)
    if not t: continue
    if "app-code" in line and ("killed" in line or "Main process exited" in line):
        rows.append((t, "EDIT ", "VS Code: " + line.split("]: ", 1)[-1][:120]))
    m = re.search(r"(chess-prep-(?:ci|driver)-\d+-\d+)\.scope: Consumed (.+?) CPU time over (.+?) wall clock time, (\S+) memory peak", line)
    if m:
        rows.append((t, "JOB  ", f"{m.group(1)} finished: {m.group(2)} cpu / {m.group(3)} wall, peak {m.group(4)}"))
        continue
    m = re.search(r"Started (chess-prep-(?:ci|driver)-\d+-\d+)\.scope - \[systemd-run\] (.+?)\.?$", line)
    if m:
        cmd = re.sub(r"\S*/flutter/bin/", "", m.group(2))
        rows.append((t, "JOB  ", f"{m.group(1)} started: {cmd[:90]}"))

# Samples where the machine was actually struggling.
try:
    since_dt = None
    r = subprocess.run(["date", "-d", since, "+%Y-%m-%dT%H:%M:%S"], capture_output=True, text=True)
    if r.returncode == 0: since_dt = r.stdout.strip()
    for line in open(log, errors="replace"):
        t = ts_of(line)
        if not t or (since_dt and t < since_dt): continue
        f = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
        load = float(f.get("load", "0/1").split("/")[0])
        swap = int(f.get("swap", "0").rstrip("%") or 0)
        mem_full = float(f.get("psi_mem", "0/0").split("/")[1] or 0)
        cpu_some = float(f.get("psi_cpu", "0") or 0)
        slice_cur, slice_max = f.get("app.slice", "0/inf").split("/")
        slice_max = slice_max.rstrip("G")
        at_cap = slice_max not in ("inf", "") and float(slice_cur) >= 0.95 * float(slice_max)
        why = []
        if load > ncpu: why.append(f"load {load:.0f} on {ncpu} cores")
        if mem_full >= 5: why.append(f"memory stall {mem_full:.0f}%")
        if cpu_some >= 50: why.append(f"cpu wait {cpu_some:.0f}%")
        if swap >= 95: why.append(f"swap {swap}%")
        if at_cap: why.append(f"app.slice at its cap ({slice_cur}/{slice_max}G)")
        if why:
            rows.append((t, "STALL", "; ".join(why) + f" — top {f.get('top','?')}, testers={f.get('testers','?')}"))
except FileNotFoundError:
    rows.append(("0000", "NOTE ", f"no samples yet: {log} does not exist — scripts/health_log.sh install"))

rows.sort()
if not rows:
    print(f"nothing since '{since}': no kills, no heavy jobs, no stalls recorded.")
for t, kind, msg in rows:
    print(f"{t[11:19] if t != '0000' else '        '}  {kind} {msg}")
PY
}

case "${1:-}" in
  install)   install_timer ;;
  uninstall) uninstall_timer ;;
  status)    status ;;
  sample)    if [[ "${2:-}" == "--record" ]]; then record; else sample; fi ;;
  tail)      tail -n "${2:-20}" "$LOG" 2>/dev/null || echo "no log yet: $LOG" ;;
  report)    shift; report "$*" ;;
  *)         sed -n '2,15p' "$0"; exit 2 ;;
esac
