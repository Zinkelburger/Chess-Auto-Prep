#!/usr/bin/env bash
# Arguments are data; never evaluated as shell code. No user data is removed.
set -euo pipefail
app_pid=$1
payload=$2
expected=$3
executable=$4
kind=$5
armed=$6
state_dir=$(dirname "$armed")
exec >>"$state_dir/install.log" 2>&1
# Serialize helpers for this installation, including helpers from another app.
exec 9>"$(dirname "$state_dir")/install.lock"
flock -n 9 || exit 1
finish() {
  result=$?
  if test "$result" -ne 0; then
    printf 'Update installation failed (exit %s). Details: %s/install.log\n' "$result" "$state_dir" > "$(dirname "$state_dir")/last-error.txt"
  fi
  rm -f -- "$state_dir/helper-ready" "$armed"
}
trap finish EXIT
printf 'ready\n' > "$state_dir/helper-ready"
while kill -0 "$app_pid" 2>/dev/null; do
  test -f "$armed" || exit 0
  sleep 1
done
test -f "$armed" || exit 0
actual=$(sha256sum -- "$payload")
test "${actual%% *}" = "$expected"
case "$kind" in
  linuxDeb) pkexec /usr/bin/dpkg --install "$payload" ;;
  linuxRpm) pkexec /usr/bin/rpm --upgrade "$payload" ;;
  linuxPortable)
    install_dir=$(dirname "$executable")
    test "$(cat "$install_dir/.chess-auto-prep-portable")" = 1
    stage=$(mktemp -d "${install_dir}.update-XXXXXXXX")
    # Reject traversal and symlink entries before unpacking a release archive.
    # Our release zip dereferences bundle symlinks.
    unzip -Z1 "$payload" > "$state_dir/entries"
    if LC_ALL=C grep -E '(^/|(^|/)\.\.(/|$)|\\)' "$state_dir/entries"; then exit 1; fi
    if unzip -Z -l "$payload" | LC_ALL=C grep -E '^l'; then exit 1; fi
    unzip -q "$payload" -d "$stage"
    test -x "$stage/chess_auto_prep"
    test -f "$stage/lib/libapp.so"
    test -f "$stage/data/icudtl.dat"
    test "$(cat "$stage/.chess-auto-prep-portable")" = 1
    # Preserve top-level additions (for example a PGN beside the executable).
    # The updater owns only the executable, lib/, data/ and its marker.
    shopt -s dotglob nullglob
    for entry in "$install_dir"/*; do
      case "$(basename "$entry")" in chess_auto_prep|lib|data|.chess-auto-prep-portable) continue ;; esac
      cp -a -- "$entry" "$stage/"
    done
    previous="${install_dir}.previous-$(date +%s)-$$"
    mv -- "$install_dir" "$previous"
    if ! mv -- "$stage" "$install_dir"; then
      mv -- "$previous" "$install_dir"
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
rm -f -- "$(dirname "$state_dir")/last-error.txt"
printf 'Installation completed.\n'
# Keep the log for failed launches; no forced rollback after a data migration.
"$executable" </dev/null >>"$state_dir/restart.log" 2>&1 9>&- &
