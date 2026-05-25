#!/usr/bin/env bash
#
# build_native.sh — Build libcdbdirect for one desktop target.
#
# Usage:
#   ./scripts/build_native.sh --target linux-x64
#   ./scripts/build_native.sh --target windows-x64   # TODO stub
#   ./scripts/build_native.sh --target macos-arm64   # TODO stub
#   ./scripts/build_native.sh --target macos-x64     # TODO stub
#
# Output: native/{target}/libcdbdirect.{so|dll|dylib}
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NATIVE_DIR="${PKG_DIR}/native"
SRC_DIR="${PKG_DIR}/src"
DEPS_DIR="${PKG_DIR}/.build/deps"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

TARGET=""
FORCE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --target TARGET [--force]

Targets:
  linux-x64     Fully supported (TerarkDB + cdbdirect)
  windows-x64   TODO — needs MSVC + vcpkg deps
  macos-arm64   TODO — needs Xcode + Homebrew deps
  macos-x64     TODO — needs Xcode + Homebrew deps

TerarkDB (noobpwnftw fork):
  - Builds via ./build.sh (not CMake), same as tree_builder/setup_cdbdirect.sh
  - Linux deps: zlib, snappy, lz4, bzip2, jemalloc, tbb, boost
  - libaio is Linux-only and used for write paths; read-only SST probing does
    not require it for our use case
  - RocksDB/TerarkDB upstream supports MSVC and Xcode; the noobpwnftw extensions
    should compile once platform toolchains and deps are wired in
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:?}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$TARGET" ]] || { usage; exit 1; }

out_dir="${NATIVE_DIR}/${TARGET}"
mkdir -p "$out_dir"

build_linux_x64() {
  local terark_dir="${DEPS_DIR}/terarkdb"
  local cdb_dir="${DEPS_DIR}/cdbdirect"
  local capi_obj="${DEPS_DIR}/cdbdirect_capi.o"
  local static_lib="${DEPS_DIR}/libcdbdirect.a"
  local shared_lib="${out_dir}/libcdbdirect.so"

  if [[ -f "$shared_lib" && "$FORCE" -eq 0 ]]; then
    echo "Already built: $shared_lib"
    return 0
  fi

  mkdir -p "$DEPS_DIR"

  if [[ ! -d "${terark_dir}/.git" ]]; then
    git clone --depth 1 https://github.com/noobpwnftw/terarkdb.git "$terark_dir"
  fi
  if [[ ! -d "${cdb_dir}/.git" ]]; then
    git clone --depth 1 https://github.com/vondele/cdbdirect.git "$cdb_dir"
  fi

  local terark_lib="${terark_dir}/output/lib/libterarkdb.a"
  if [[ ! -f "$terark_lib" || "$FORCE" -eq 1 ]]; then
    echo "Building TerarkDB (Release, -fPIC, -march=x86-64)..."
    export CFLAGS="-fPIC -march=x86-64 ${CFLAGS:-}"
    export CXXFLAGS="-fPIC -march=x86-64 ${CXXFLAGS:-}"
    export EXTRA_CFLAGS="-fPIC -march=x86-64"
    export EXTRA_CXXFLAGS="-fPIC -march=x86-64"
    pushd "$terark_dir" >/dev/null
    git submodule update --init --recursive
    rm -rf output
    WITH_TESTS=OFF WITH_TOOLS=OFF WITH_ZNS=OFF ./build.sh
    popd >/dev/null
  else
    echo "TerarkDB already built: $terark_lib"
  fi

  [[ -f "$terark_lib" ]] || { echo "TerarkDB build failed" >&2; exit 1; }

  echo "Building libcdbdirect.a..."
  pushd "$cdb_dir" >/dev/null
  make clean 2>/dev/null || true
  make lib -j"$JOBS" \
    TERARKDBROOT="$terark_dir" \
    CHESSDB_PATH="/tmp/chessdb_unused"
  popd >/dev/null
  cp "${cdb_dir}/libcdbdirect.a" "$static_lib"

  echo "Adding C API wrapper..."
  local cxxflags="-Wall -flto=auto -fPIC -O3 -g -DNDEBUG -march=x86-64 -fomit-frame-pointer"
  local incflags="-I${cdb_dir} -I${terark_dir}/output/include \
    -I${terark_dir}/third-party/terark-zip/src -I${terark_dir}/include"
  g++ $cxxflags $incflags -c "${SRC_DIR}/cdbdirect_capi.cpp" -o "$capi_obj"
  ar q "$static_lib" "$capi_obj"

  echo "Linking $shared_lib ..."
  g++ -shared -fPIC -flto=auto -o "$shared_lib" \
    -Wl,--whole-archive "$static_lib" -Wl,--no-whole-archive \
    -L"${terark_dir}/output/lib" \
    -lterarkdb -lterark-zip-r -lboost_fiber -lboost_context \
    -ljemalloc -ltbb -lsnappy -llz4 -lz -lbz2 -latomic \
    -pthread -lrt -ldl -lgomp -lgcc \
    -Wl,-rpath,'\$ORIGIN'

  echo "Built $shared_lib"
  ldd "$shared_lib" | head -20 || true
}

build_windows_x64_stub() {
  cat >&2 <<'EOF'
windows-x64: NOT YET IMPLEMENTED

What is needed:
  1. Visual Studio 2022 with C++ desktop workload
  2. vcpkg packages: zlib, snappy, lz4, bzip2, tbb, boost-fiber
  3. Build noobpwnftw/terarkdb with MSVC (WITH_TESTS=OFF, WITH_TOOLS=OFF)
  4. Build vondele/cdbdirect against TERARKDBROOT
  5. Link cdbdirect_capi.cpp into cdbdirect.dll with /WHOLEARCHIVE on the .lib
  6. Copy output to native/windows-x64/cdbdirect.dll

TerarkDB is RocksDB-based; MSVC builds are supported upstream. libaio is
Linux-only and not required for read-only SST access.
EOF
  exit 2
}

build_macos_stub() {
  local arch="$1"
  cat >&2 <<EOF
macos-${arch}: NOT YET IMPLEMENTED

What is needed:
  1. Xcode command-line tools
  2. Homebrew: cmake, boost, tbb, snappy, lz4, jemalloc, zlib, bzip2
  3. Build TerarkDB with ./build.sh (Release, -fPIC)
  4. Build cdbdirect + cdbdirect_capi.cpp
  5. Link libcdbdirect.dylib with -Wl,-rpath,@loader_path
  6. Copy to native/macos-${arch}/libcdbdirect.dylib

Use: arch -${arch} ./scripts/build_native.sh --target macos-${arch}
EOF
  exit 2
}

case "$TARGET" in
  linux-x64)
    build_linux_x64
    ;;
  windows-x64)
    build_windows_x64_stub
    ;;
  macos-arm64)
    build_macos_stub arm64
    ;;
  macos-x64)
    build_macos_stub x86_64
    ;;
  *)
    echo "Unknown target: $TARGET" >&2
    usage
    exit 1
    ;;
esac
