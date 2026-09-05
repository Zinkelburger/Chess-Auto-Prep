#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash matcher): refuse raw heavy Flutter commands.
#
# Every `flutter test` / `flutter analyze` / `flutter run` / `flutter build` /
# `flutter drive` / `xvfb-run` must go through scripts/ci.sh (or the app
# driver), so jobs share the bounded resource runner. Other commands pass.
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)

# Resource admission and limits are handled inside these entrypoints.
case "$cmd" in
  *scripts/ci.sh*|*scripts/agent_job.py*|*scripts/app_driver.py*|*run-chess-auto-prep/driver.py*|*scripts/hooks/flutter_gate.sh*) exit 0 ;;
esac

# `flutter <heavy verb>` — `flutter`, `~/sdk/flutter/bin/flutter`, `fvm flutter`
# and friends all end in `flutter` before the verb. For `dart` only `test` and
# `build_runner` are heavy: `dart run tools/run_engine_tournament.dart` or a
# `dart run` inside tools/dart_api_test is a plain VM script, not a Flutter
# build, and the docs tell agents to use those. Keep this list in step with
# the "Local agent workflow" section of CLAUDE.md.
flutter_heavy='(^|[;&|[:space:]])([^[:space:];&|]*/)?flutter[[:space:]]+(test|analyze|run|build|drive|pub[[:space:]]+run[[:space:]]+build_runner)([[:space:]]|$)'
dart_heavy='(^|[;&|[:space:]])([^[:space:];&|]*/)?dart[[:space:]]+(test|run[[:space:]]+build_runner|pub[[:space:]]+run[[:space:]]+build_runner)([[:space:]]|$)'
if [[ "$cmd" =~ $flutter_heavy ]] || [[ "$cmd" =~ $dart_heavy ]] || [[ "$cmd" =~ (^|[;&|[:space:]])xvfb-run([[:space:]]|$) ]]; then
  reason="Use scripts/ci.sh for focused tests/builds or scripts/app_driver.py for headless app checks. These enforce two job slots and CPU/memory caps; raw heavy commands bypass containment."
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
