#!/bin/bash
# Run Chess Auto Prep with cdbdirect support (local ChessDB TerarkDB dump).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDB_LIB="${ROOT}/tree_builder/deps/install/lib"

if [[ -f "${CDB_LIB}/libcdbdirect.so" ]]; then
  export LD_LIBRARY_PATH="${CDB_LIB}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  export TERARKDBROOT="${ROOT}/tree_builder/deps/install"
fi

export CHESS_AUTO_PREP_ROOT="${ROOT}"

cd "${ROOT}"
exec flutter run -d linux "$@"
