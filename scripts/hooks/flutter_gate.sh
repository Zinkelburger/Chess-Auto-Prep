#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash matcher): refuse raw heavy Flutter commands.
#
# Every `flutter test` / `flutter analyze` / `flutter run` / `flutter build` /
# `flutter drive` / `xvfb-run` must go through scripts/ci.sh (or the app
# driver, which takes the same lock), so parallel agents queue instead of
# running five builds at once and crashing the machine. Anything else is
# allowed through untouched.
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)

# Already going through the gate — the lock is taken inside these.
case "$cmd" in
  *scripts/ci.sh*|*run-chess-auto-prep/driver.py*|*scripts/hooks/flutter_gate.sh*) exit 0 ;;
esac

# `flutter <heavy verb>` — `flutter`, `~/sdk/flutter/bin/flutter`, `fvm flutter`
# and friends all end in `flutter` before the verb. For `dart` only `test` and
# `build_runner` are heavy: `dart run tools/run_engine_tournament.dart` or a
# `dart run` inside tools/dart_api_test is a plain VM script, not a Flutter
# build, and the docs tell agents to use those. Keep this list in step with
# the "Keeping CI green" section of CLAUDE.md.
flutter_heavy='(^|[;&|[:space:]])([^[:space:];&|]*/)?flutter[[:space:]]+(test|analyze|run|build|drive|pub[[:space:]]+run[[:space:]]+build_runner)([[:space:]]|$)'
dart_heavy='(^|[;&|[:space:]])([^[:space:];&|]*/)?dart[[:space:]]+(test|run[[:space:]]+build_runner|pub[[:space:]]+run[[:space:]]+build_runner)([[:space:]]|$)'
if [[ "$cmd" =~ $flutter_heavy ]] || [[ "$cmd" =~ $dart_heavy ]] || [[ "$cmd" =~ (^|[;&|[:space:]])xvfb-run([[:space:]]|$) ]]; then
  reason="Heavy Flutter jobs are serialised machine-wide. Use scripts/ci.sh (analyze | test | integration | lint | format, or 'scripts/ci.sh with -- <cmd>' to queue an arbitrary command), or the app driver .claude/skills/run-chess-auto-prep/driver.py. Both take the shared lock so parallel agents queue instead of crashing the machine."
  python3 - "$reason" <<'EOF'
import json, sys
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": sys.argv[1],
    }
}))
EOF
fi
exit 0
