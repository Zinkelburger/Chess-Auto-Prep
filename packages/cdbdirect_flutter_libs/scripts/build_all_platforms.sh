#!/usr/bin/env bash
#
# build_all_platforms.sh — Build cdbdirect for every desktop target.
#
# Linux is fully automated. Windows/macOS print TODO instructions until CI
# toolchains are wired up.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGETS=(linux-x64 windows-x64 macos-arm64 macos-x64)
FAILED=()

for target in "${TARGETS[@]}"; do
  echo "══════════════════════════════════════════════════════════════"
  echo " Target: $target"
  echo "══════════════════════════════════════════════════════════════"
  if "${SCRIPT_DIR}/build_native.sh" --target "$target"; then
    echo "✓ $target"
  else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "! $target — stub (see instructions above)"
    else
      echo "✗ $target failed (exit $rc)"
      FAILED+=("$target")
    fi
  fi
  echo
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Failed targets: ${FAILED[*]}" >&2
  exit 1
fi

echo "Done. Prebuilt libraries are under packages/cdbdirect_flutter_libs/native/"
