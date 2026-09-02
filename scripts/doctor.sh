#!/usr/bin/env bash
# scripts/doctor.sh — is this checkout in a state where work will succeed?
#
# An agent landing in this repo shares the tree, the machine and the Flutter
# lock with several other sessions, and every one of the checks below has cost
# somebody a wasted build at least once. All of them are read-only and none of
# them take the lock, so this is always safe to run first.
#
#   scripts/doctor.sh          # report; exit 1 if something blocks work
#   scripts/doctor.sh --quiet  # only the problems
#
# Exit codes: 0 all clear · 1 something is blocking · 2 doctor itself broke.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

problems=0
notes=0

ok()   { [[ $QUIET -eq 1 ]] || printf '  \033[32mok\033[0m    %s\n' "$*"; }
note() { notes=$((notes + 1)); printf '  \033[33mnote\033[0m  %s\n' "$*"; }
bad()  { problems=$((problems + 1)); printf '  \033[31mBLOCK\033[0m %s\n' "$*"; }
hdr()  { [[ $QUIET -eq 1 ]] || printf '\n\033[1m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------------------
hdr "Toolchain"
# --------------------------------------------------------------------------
# Same resolution order as ci.sh and driver.py: ~/sdk/flutter first, PATH after.
if [[ -n "${FLUTTER:-}" && -x "${FLUTTER:-}" ]]; then
  flutter_bin=$FLUTTER
elif [[ -x "$HOME/sdk/flutter/bin/flutter" ]]; then
  flutter_bin="$HOME/sdk/flutter/bin/flutter"
else
  flutter_bin=$(command -v flutter || true)
fi
if [[ -x "$flutter_bin" ]]; then
  froot=$(cd "$(dirname "$flutter_bin")/.." && pwd)
  ver=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["flutterVersion"])' \
        "$froot/bin/cache/flutter.version.json" 2>/dev/null \
        || sed -n '1p' "$froot/version" 2>/dev/null || echo "?")
  ok "flutter $ver ($flutter_bin)"
  pinned=$(grep -oP "flutter-version:\s*['\"]?\K[0-9.]+" .github/workflows/ci.yml 2>/dev/null | head -1)
  if [[ -n "$pinned" && -n "$ver" && "$ver" != "?" && "$ver" != "$pinned" ]]; then
    note "CI pins Flutter $pinned but this machine has $ver — \`dart format\` output can differ from CI's"
  fi
else
  bad "flutter not found (tried \$FLUTTER, ~/sdk/flutter/bin/flutter, PATH)"
fi
command -v python3 >/dev/null && ok "python3 $(python3 -V 2>&1 | cut -d' ' -f2)" \
  || bad "python3 missing — driver.py and the gate hook both need it"

# --------------------------------------------------------------------------
hdr "Bundled assets"
# --------------------------------------------------------------------------
# The Stockfish binaries are gitignored and fetched; pubspec.yaml bundles them,
# so a missing one fails `flutter build` late and confusingly.
if [[ -f tools/fetch_assets.py ]]; then
  if out=$(python3 tools/fetch_assets.py --check 2>&1); then
    ok "fetched assets present ($(grep -c '^\[ok' <<<"$out") of $(grep -c '^\[' <<<"$out"))"
  else
    bad "fetched assets missing or stale — run: python3 tools/fetch_assets.py"
    [[ $QUIET -eq 1 ]] || sed 's/^/        /' <<<"$out" | grep -v '\[ok' | head -5
  fi
fi
# No upstream to re-fetch this one from: git is the only copy.
[[ -f assets/maia3_simplified.onnx ]] && ok "maia3_simplified.onnx present" \
  || bad "assets/maia3_simplified.onnx missing — it has no upstream, restore it from git"

# --------------------------------------------------------------------------
hdr "Shared machine"
# --------------------------------------------------------------------------
LOCK=${CHESS_PREP_LOCK:-/tmp/chess-auto-prep-flutter.lock}
if [[ -r "$LOCK.holder" ]] && ! flock -n "$LOCK" true 2>/dev/null; then
  note "Flutter lock held by: $(cat "$LOCK.holder") — heavy jobs will queue behind it"
else
  ok "Flutter lock free"
fi

drv=$(python3 .claude/skills/run-chess-auto-prep/driver.py status 2>/dev/null)
case "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print("usable" if d.get("usable") else ("stale" if d.get("state",{}).get("status")=="running" else "down"))' <<<"$drv" 2>/dev/null)" in
  usable) ok "app driver running ($(python3 -c 'import json,sys; print(json.load(sys.stdin)["state"].get("src","?"))' <<<"$drv"))" ;;
  stale)  note "app driver state says 'running' but the process is gone — \`driver.py start\` will re-launch" ;;
  *)      ok "app driver down (start it with driver.py start --worktree)" ;;
esac

# --------------------------------------------------------------------------
hdr "Working tree"
# --------------------------------------------------------------------------
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
dirty=$(git status --porcelain 2>/dev/null | grep -c .)
ok "on $branch, $dirty uncommitted path(s)"
if [[ $dirty -gt 40 ]]; then
  note "$dirty dirty paths — the tree is probably mid-refactor by another session. If it does not compile, do not fix it: launch from a snapshot (driver.py start --worktree)"
fi
wt=$(git worktree list 2>/dev/null | grep -cv "^$ROOT ")
[[ $wt -gt 0 ]] && note "$wt other git worktree(s) attached — see \`git worktree list\`"

# --------------------------------------------------------------------------
hdr "Agent contract"
# --------------------------------------------------------------------------
# These are what make an agent's runs reproducible on a fresh clone.
for f in .claude/settings.json .claude/commands/gate.md \
         .claude/skills/run-chess-auto-prep/SKILL.md \
         .claude/skills/run-chess-auto-prep/driver.py \
         scripts/ci.sh scripts/doctor.sh scripts/hooks/flutter_gate.sh \
         lib/debug/agent_driver.dart; do
  if [[ ! -e "$f" ]]; then
    bad "$f missing"
  elif git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    ok "$f tracked"
  else
    bad "$f is UNTRACKED — it exists only on this machine; a clone gets CLAUDE.md telling it to run a script that is not there"
  fi
done
[[ -x scripts/hooks/flutter_gate.sh ]] || bad "scripts/hooks/flutter_gate.sh is not executable — the gate silently does nothing"
[[ -x scripts/ci.sh ]] || bad "scripts/ci.sh is not executable"
# `driver.py start --worktree` builds HEAD, so the wiring must exist in HEAD —
# not just in somebody's working tree — or the driver hangs waiting for
# extensions that were never registered.
if ! git show HEAD:lib/main.dart 2>/dev/null | grep -q installAgentDriver; then
  bad "HEAD's lib/main.dart does not call installAgentDriver() — \`driver.py start --worktree\` will build an app the driver cannot talk to"
fi

# --------------------------------------------------------------------------
hdr "Conventions"
# --------------------------------------------------------------------------
# ci.sh lint is the single source of truth for the layering and type greps;
# it is cheap and never takes the lock, so run the real thing rather than a copy.
if lint=$(scripts/ci.sh lint 2>&1); then
  ok "layering + type-size lint clean"
else
  bad "lint failures (run \`scripts/ci.sh lint\`)"
  [[ $QUIET -eq 1 ]] || sed 's/^/        /' <<<"$lint" | grep -v '── lint greps' | head -10
fi

CACHE_DIR=${CHESS_PREP_CI_CACHE:-/tmp/chess-auto-prep-ci}
cached=$(scripts/ci.sh status 2>/dev/null | tail -n +3 | grep -c .)
[[ $cached -gt 0 ]] && ok "$cached cached gate pass(es) for this exact tree" \
  || ok "no cached gate passes for this tree — \`scripts/ci.sh\` will run for real"

# --------------------------------------------------------------------------
printf '\n'
if [[ $problems -gt 0 ]]; then
  printf '\033[31m%d blocking problem(s)\033[0m, %d note(s).\n' "$problems" "$notes"
  exit 1
fi
printf '\033[32mall clear\033[0m — %d note(s).\n' "$notes"
