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

# The bughouse engine is optional: the app hides Bughouse Lab when it is not
# bundled, so a checkout without it is fine and only worth a note. What is NOT
# fine is the directory itself going missing -- pubspec.yaml declares it, and
# `flutter build` treats a missing asset directory as a warning and exits 0, so
# losing .gitkeep means a release silently ships with no engine.
if [[ ! -f assets/bughouse/.gitkeep ]]; then
  bad "assets/bughouse/.gitkeep is missing — restore it from git, or a release will build green with no bughouse engine"
elif [[ -f tools/fetch_bughouse.py ]]; then
  if out=$(python3 tools/fetch_bughouse.py --check 2>&1); then
    ok "bughouse engine present ($(grep -c '^\[ok' <<<"$out") files)"
    # Cheap and static: reads the fetched binaries' own import tables. It is
    # what says a Windows bundle needs a DLL nobody ships, which is invisible
    # on any machine that happens to have it.
    if deps=$(python3 tools/test_bughouse_engine.py deps --all 2>&1); then
      ok "bughouse engine dependencies all guaranteed or shipped"
    else
      bad "bughouse engine has an unmet dependency:"
      sed 's/^/    /' <<<"$deps" | tail -3
    fi
  else
    note "bughouse engine not fetched — Bughouse Lab stays hidden. To enable: python3 tools/fetch_bughouse.py"
  fi
fi

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
# These are what make an agent's runs reproducible on a fresh clone. The list
# is the whole contract: CLAUDE.md, the MCP registration, the hook, the slash
# commands, both skills, the gate scripts and the in-app driver hooks.
contract=(CLAUDE.md .mcp.json .claude/settings.json
          .claude/commands/doctor.md .claude/commands/drive.md
          .claude/commands/gate.md .claude/commands/run-skill-generator.md
          .claude/skills/run-chess-auto-prep/SKILL.md
          .claude/skills/run-chess-auto-prep/driver.py
          .claude/skills/chess-prep-mcp/SKILL.md
          .claude/skills/chess-prep-mcp/mcp_tools.py
          .claude/skills/bughouse-mcp/SKILL.md
          scripts/ci.sh scripts/doctor.sh scripts/hooks/flutter_gate.sh
          lib/debug/agent_driver.dart tools/mcp/chess_prep/__main__.py
          tools/mcp/mcp_stdio.py tools/mcp/bughouse/__main__.py)
tracked=0
for f in "${contract[@]}"; do
  if [[ ! -e "$f" ]]; then
    bad "$f missing"
  elif git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    tracked=$((tracked + 1))
  else
    bad "$f is UNTRACKED — it exists only on this machine; a clone gets CLAUDE.md telling it to run a script that is not there"
  fi
done
[[ $tracked -eq ${#contract[@]} ]] && ok "all ${#contract[@]} contract files tracked"
# Anything new under .claude/ that nobody added yet is the same bug in waiting.
stray=$(git ls-files --others --exclude-standard .claude scripts/hooks 2>/dev/null | grep -v __pycache__ || true)
[[ -n "$stray" ]] && bad "untracked under .claude/ or scripts/hooks/ — git add or delete: $(tr '\n' ' ' <<<"$stray")"
# Every skill needs frontmatter with a name and a description that says when
# to trigger; a skill without one never fires. Stdlib parse, no PyYAML needed.
for sk in .claude/skills/*/SKILL.md; do
  if ! python3 - "$sk" <<'PY' 2>/dev/null
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
fm = m.group(1) if m else ""
name = re.search(r"^name:\s*(\S+)", fm, re.M)
desc = re.search(r"^description:\s*(\S.*)", fm, re.M)
sys.exit(0 if (name and desc and len(desc.group(1)) > 40) else 1)
PY
  then bad "$sk: frontmatter needs \`name:\` and a \`description:\` that says when to trigger"; fi
done
[[ -x scripts/hooks/flutter_gate.sh ]] || bad "scripts/hooks/flutter_gate.sh is not executable — the gate silently does nothing"
[[ -x scripts/ci.sh ]] || bad "scripts/ci.sh is not executable"
grep -q 'scripts/hooks/flutter_gate.sh' .claude/settings.json 2>/dev/null \
  || bad ".claude/settings.json no longer wires scripts/hooks/flutter_gate.sh as a PreToolUse hook"
# `driver.py start --worktree` builds HEAD, so the wiring must exist in HEAD —
# not just in somebody's working tree — or the driver hangs waiting for
# extensions that were never registered.
if ! git show HEAD:lib/main.dart 2>/dev/null | grep -q installAgentDriver; then
  bad "HEAD's lib/main.dart does not call installAgentDriver() — \`driver.py start --worktree\` will build an app the driver cannot talk to"
fi

# --------------------------------------------------------------------------
hdr "MCP server"
# --------------------------------------------------------------------------
# .mcp.json runs the server from the working tree; an import error there
# takes every mcp__chess-prep__* tool down with it.
for server in chess_prep bughouse; do
  if out=$(python3 .claude/skills/chess-prep-mcp/mcp_tools.py --server "$server" check 2>&1); then
    ok "$out"
  else
    bad "$server MCP server does not answer tools/list (python3 .claude/skills/chess-prep-mcp/mcp_tools.py --server $server check)"
    [[ $QUIET -eq 1 ]] || sed 's/^/        /' <<<"$out" | tail -5
  fi
done
if python3 -c 'import chess' 2>/dev/null; then
  ok "python-chess installed (pgn_*, master_*, expectimax_*, chessdb_query work)"
else
  note "python-chess missing — pgn_*, master_*, expectimax_* and chessdb_query will fail: pip install -r tools/mcp/requirements.txt"
fi
mcp_dirty=$(git status --porcelain tools/mcp 2>/dev/null | grep -v __pycache__ | grep -c .)
[[ $mcp_dirty -gt 0 ]] && note "$mcp_dirty uncommitted path(s) under tools/mcp — the MCP tools run that in-progress code"

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
