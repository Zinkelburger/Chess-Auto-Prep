#!/usr/bin/env bash
#
# setup_cdbdirect.sh — Build TerarkDB + cdbdirect for Chess-Auto-Prep.
#
# Usage:
#   ./scripts/setup_cdbdirect.sh [--dump-path /mnt/hdd/chessdb/data] [--force] [--skip-smoke]
#
# Idempotent: safe to re-run; skips steps whose outputs already exist unless --force.
#
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED= GREEN= YELLOW= BLUE= BOLD= NC=
fi

info()    { printf '%s\n' "${BLUE}▸${NC} $*"; }
ok()      { printf '%s\n' "${GREEN}✓${NC} $*"; }
warn()    { printf '%s\n' "${YELLOW}!${NC} $*"; }
err()     { printf '%s\n' "${RED}✗${NC} $*" >&2; }
section() { printf '\n%s%s%s\n' "${BOLD}" "$*" "${NC}"; }

die() {
    err "$1"
    echo
    err "Setup failed. See messages above for how to fix it."
    exit 1
}

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE_BUILDER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPS_DIR="${TREE_BUILDER_DIR}/deps"
TERARKDB_DIR="${DEPS_DIR}/terarkdb"
CDBDIRECT_DIR="${DEPS_DIR}/cdbdirect"
INSTALL_DIR="${DEPS_DIR}/install"
CAPI_SRC="${SCRIPT_DIR}/cdbdirect_capi.cpp"

TERARKDB_REPO="https://github.com/noobpwnftw/terarkdb.git"
CDBDIRECT_REPO="https://github.com/vondele/cdbdirect.git"

DUMP_PATH=""
FORCE=0
SKIP_SMOKE=0
JOBS="$(nproc 2>/dev/null || echo 4)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build TerarkDB and cdbdirect into tree_builder/deps/ for HAS_CDBDIRECT support.

Options:
  --dump-path PATH   ChessDB TerarkDB data directory (enables smoke test)
  --force            Rebuild even if outputs already exist
  --skip-smoke       Skip smoke test even when --dump-path is set
  --jobs N           Parallel make jobs (default: ${JOBS})
  -h, --help         Show this help

Example:
  ./scripts/setup_cdbdirect.sh --dump-path /mnt/hdd/chess-20251115/data
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dump-path)   DUMP_PATH="${2:?--dump-path requires a path}"; shift 2 ;;
        --force)       FORCE=1; shift ;;
        --skip-smoke)  SKIP_SMOKE=1; shift ;;
        --jobs)        JOBS="${2:?--jobs requires a number}"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "Unknown option: $1 (try --help)" ;;
    esac
done

# ── Distro detection ────────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
            *fedora*|*rhel*|*centos*) echo "fedora" ;;
            *debian*|*ubuntu*)        echo "debian" ;;
            *arch*)                   echo "arch" ;;
            *)                        echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

DISTRO="$(detect_distro)"

install_hint() {
    local pkg="$1"
    case "$DISTRO" in
        fedora)
            echo "  sudo dnf install ${pkg}"
            ;;
        debian)
            echo "  sudo apt install ${pkg}"
            ;;
        arch)
            echo "  sudo pacman -S ${pkg}"
            ;;
        *)
            echo "  Install ${pkg} using your system package manager."
            ;;
    esac
}

# pkg_name -> "fedora debian arch" mapping for required tools/libs
pkg_for() {
    case "$1" in
        cmake)     echo "cmake cmake cmake" ;;
        g++)       echo "gcc-c++ g++ gcc" ;;
        git)       echo "git git git" ;;
        zlib)      echo "zlib-devel zlib1g-dev zlib" ;;
        snappy)    echo "snappy-devel libsnappy-dev snappy" ;;
        lz4)       echo "lz4-devel liblz4-dev lz4" ;;
        bzip2)     echo "bzip2-devel libbz2-dev bzip2" ;;
        jemalloc)  echo "jemalloc-devel libjemalloc-dev jemalloc" ;;
        tbb)       echo "tbb-devel libtbb-dev tbb" ;;
        boost)     echo "boost-devel libboost-all-dev boost" ;;
        autoconf)  echo "autoconf autoconf autoconf" ;;
        make)      echo "make make make" ;;
        curl)      echo "curl curl curl" ;;
        *)         echo "" ;;
    esac
}

distro_pkg() {
    local key="$1"
    read -r fed deb arch <<< "$(pkg_for "$key")"
    case "$DISTRO" in
        fedora) echo "$fed" ;;
        debian) echo "$deb" ;;
        arch)   echo "$arch" ;;
        *)      echo "$key" ;;
    esac
}

# ── Dependency checks ───────────────────────────────────────────────────────
section "Checking system dependencies"

MISSING=()

require_cmd() {
    local cmd="$1" pkg_key="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "found: $cmd"
    else
        MISSING+=("$(distro_pkg "$pkg_key")")
        err "missing: $cmd ($(distro_pkg "$pkg_key"))"
    fi
}

require_pkgconfig() {
    local pc_name="$1" pkg_key="$2" label="$3"
    if pkg-config --exists "$pc_name" 2>/dev/null; then
        ok "found: $label"
    else
        MISSING+=("$(distro_pkg "$pkg_key")")
        err "missing: $label (pkg-config: $pc_name)"
    fi
}

require_cmd cmake cmake
require_cmd g++   g++
require_cmd git   git
require_cmd make  make

require_pkgconfig zlib   zlib   "zlib"
require_pkgconfig snappy snappy "snappy"
require_pkgconfig liblz4 lz4    "lz4"
require_pkgconfig bzip2  bzip2  "bzip2"

# jemalloc may not have .pc on all distros
if pkg-config --exists jemalloc 2>/dev/null || \
   [[ -f /usr/lib/libjemalloc.so || -f /usr/lib64/libjemalloc.so ]]; then
    ok "found: jemalloc"
else
    MISSING+=("$(distro_pkg jemalloc)")
    err "missing: jemalloc"
fi

# Boost / TBB needed by cdbdirect link line
if [[ -f /usr/include/boost/fiber/all.hpp ]] || \
   [[ -f /usr/local/include/boost/fiber/all.hpp ]]; then
    ok "found: Boost (headers)"
else
    MISSING+=("$(distro_pkg boost)")
    err "missing: Boost headers ($(distro_pkg boost))"
fi

if pkg-config --exists tbb 2>/dev/null || \
   [[ -f /usr/lib/libtbb.so || -f /usr/lib64/libtbb.so ]]; then
    ok "found: TBB"
else
    MISSING+=("$(distro_pkg tbb)")
    err "missing: TBB"
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo
    err "Install the missing packages, then re-run this script:"
    # dedupe
    declare -A seen=()
    for pkg in "${MISSING[@]}"; do
        [[ -n "$pkg" && -z "${seen[$pkg]+x}" ]] || continue
        seen[$pkg]=1
        install_hint "$pkg"
    done
    exit 1
fi

mkdir -p "${DEPS_DIR}" "${INSTALL_DIR}/include" "${INSTALL_DIR}/lib"

# ── Clone TerarkDB ────────────────────────────────────────────────────────────
section "TerarkDB (noobpwnftw fork)"

clone_or_update() {
    local url="$1" dir="$2" name="$3"
    if [[ -d "${dir}/.git" ]]; then
        info "${name} already cloned at ${dir}"
        if [[ "$FORCE" -eq 1 ]]; then
            info "Updating ${name} (--force)..."
            git -C "$dir" fetch --depth 1 origin 2>/dev/null || true
            git -C "$dir" pull --ff-only 2>/dev/null || warn "Could not fast-forward ${name}; using existing checkout"
        fi
    else
        info "Cloning ${name}..."
        git clone --depth 1 "$url" "$dir"
        ok "Cloned ${name}"
    fi
}

clone_or_update "$TERARKDB_REPO" "$TERARKDB_DIR" "TerarkDB"

TERARK_LIB="${TERARKDB_DIR}/output/lib/libterarkdb.a"

build_terarkdb() {
    if [[ -f "$TERARK_LIB" && "$FORCE" -eq 0 ]]; then
        ok "TerarkDB already built (${TERARK_LIB})"
        return 0
    fi

    info "Building TerarkDB (Release, -fPIC, no tests/tools) — this takes several minutes..."
    export CFLAGS="-fPIC ${CFLAGS:-}"
    export CXXFLAGS="-fPIC ${CXXFLAGS:-}"
    export EXTRA_CFLAGS="-fPIC"
    export EXTRA_CXXFLAGS="-fPIC"

    pushd "$TERARKDB_DIR" >/dev/null
    git submodule update --init --recursive
    rm -rf output
    WITH_TESTS=OFF WITH_TOOLS=OFF WITH_ZNS=OFF ./build.sh
    popd >/dev/null

    [[ -f "$TERARK_LIB" ]] || die "TerarkDB build failed: ${TERARK_LIB} not found"
    ok "TerarkDB built successfully"
}

build_terarkdb

# ── Install TerarkDB headers/libs ───────────────────────────────────────────
section "Installing TerarkDB to ${INSTALL_DIR}"

install_terarkdb_artifacts() {
    info "Copying headers and libraries..."
    rm -rf "${INSTALL_DIR}/include/rocksdb" "${INSTALL_DIR}/include/table" 2>/dev/null || true
    cp -a "${TERARKDB_DIR}/output/include/." "${INSTALL_DIR}/include/"
    cp -a "${TERARKDB_DIR}/output/lib/." "${INSTALL_DIR}/lib/"
    ok "TerarkDB artifacts installed"
}

install_terarkdb_artifacts

# ── Clone & build cdbdirect ───────────────────────────────────────────────────
section "cdbdirect (vondele)"

clone_or_update "$CDBDIRECT_REPO" "$CDBDIRECT_DIR" "cdbdirect"

CDB_STATIC="${CDBDIRECT_DIR}/libcdbdirect.a"
CDB_SHARED="${INSTALL_DIR}/lib/libcdbdirect.so"

build_cdbdirect() {
    if [[ -f "$CDB_STATIC" && -f "$CDB_SHARED" && "$FORCE" -eq 0 ]]; then
        ok "cdbdirect already built"
        return 0
    fi

    info "Building libcdbdirect.a..."
    pushd "$CDBDIRECT_DIR" >/dev/null
    make clean 2>/dev/null || true
    make lib -j"$JOBS" \
        TERARKDBROOT="$TERARKDB_DIR" \
        CHESSDB_PATH="${DUMP_PATH:-/tmp/chessdb_unused}"
    popd >/dev/null

    [[ -f "$CDB_STATIC" ]] || die "cdbdirect static library not found after make lib"

    info "Adding C API wrapper to static library..."
    local capi_obj="${DEPS_DIR}/cdbdirect_capi.o"
    local cxxflags="-Wall -flto=auto -fPIC -O3 -g -DNDEBUG -march=native -fomit-frame-pointer"
    local incflags="-I${CDBDIRECT_DIR} -I${TERARKDB_DIR}/output/include \
        -I${TERARKDB_DIR}/third-party/terark-zip/src -I${TERARKDB_DIR}/include"

    g++ $cxxflags $incflags -c "$CAPI_SRC" -o "$capi_obj"
    ar q "$CDB_STATIC" "$capi_obj"
    cp "$CDB_STATIC" "${INSTALL_DIR}/lib/"
    cp "${CDBDIRECT_DIR}/cdbdirect.h" "${INSTALL_DIR}/include/"

    info "Linking libcdbdirect.so for Flutter FFI..."
    local terark_lib="${TERARKDB_DIR}/output/lib"
    g++ -shared -fPIC -flto=auto -o "$CDB_SHARED" \
        -Wl,--whole-archive "$CDB_STATIC" -Wl,--no-whole-archive \
        -L"$terark_lib" \
        -lterarkdb -lterark-zip-r -lboost_fiber -lboost_context \
        -ljemalloc -ltbb -lsnappy -llz4 -lz -lbz2 -latomic \
        -pthread -lrt -ldl -lgomp -lgcc \
        -Wl,-rpath,"\$ORIGIN"

    [[ -f "$CDB_SHARED" ]] || die "Failed to build ${CDB_SHARED}"
    ok "Built libcdbdirect.a and libcdbdirect.so"
}

build_cdbdirect

# ── Environment instructions ──────────────────────────────────────────────────
section "Environment setup"

BASHRC_BLOCK="
# Chess-Auto-Prep cdbdirect (added by setup_cdbdirect.sh)
export TERARKDBROOT=\"${INSTALL_DIR}\"
export LD_LIBRARY_PATH=\"\${TERARKDBROOT}/lib:\${LD_LIBRARY_PATH:-}\""

if [[ -n "$DUMP_PATH" ]]; then
    BASHRC_BLOCK+="
export CHESSDB_PATH=\"${DUMP_PATH}\""
fi

printf '%s\n' "$BASHRC_BLOCK"
echo
info "Add the block above to ~/.bashrc (or export in your shell), then run: source ~/.bashrc"
echo
info "Build tree_builder with cdbdirect:"
echo "  cd ${TREE_BUILDER_DIR}"
echo "  make HAS_CDBDIRECT=1 TERARKDBROOT=${INSTALL_DIR}"
echo
info "Flutter loads libcdbdirect.so from TERARKDBROOT/lib (or LD_LIBRARY_PATH)."
echo "  Library: ${CDB_SHARED}"
echo
info "See CDBDIRECT_SETUP.md for CLI examples, dump download, and troubleshooting."

# ── Smoke test ────────────────────────────────────────────────────────────────
if [[ -n "$DUMP_PATH" && "$SKIP_SMOKE" -eq 0 ]]; then
    section "Smoke test (ChessDB dump)"

    resolve_dump_path() {
        local p="$1"
        if [[ -f "${p}/CURRENT" || -f "${p}/LOCK" ]]; then
            echo "$p"
            return 0
        fi
        if [[ -d "${p}/data" ]]; then
            echo "${p}/data"
            return 0
        fi
        echo "$p"
    }

    RESOLVED_DUMP="$(resolve_dump_path "$DUMP_PATH")"

    if [[ ! -d "$RESOLVED_DUMP" ]]; then
        warn "Dump path not found: ${RESOLVED_DUMP} — skipping smoke test"
        warn "Re-run with --dump-path once your download finishes."
    elif [[ ! -f "${RESOLVED_DUMP}/CURRENT" && ! -f "${RESOLVED_DUMP}/LOCK" ]]; then
        warn "Directory does not look like a TerarkDB data dir (no CURRENT/LOCK): ${RESOLVED_DUMP}"
        warn "Skipping smoke test."
    else
        SMOKE_BIN="${DEPS_DIR}/cdbdirect_smoke"
        SMOKE_SRC="${DEPS_DIR}/cdbdirect_smoke.c"
        cat > "$SMOKE_SRC" <<'SMOKE_EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *(*init_fn)(const char *);
typedef const char *(*get_fn)(void *, const char *);
typedef size_t (*size_fn)(void *);
typedef void (*fin_fn)(void *);

int main(int argc, char **argv) {
    const char *lib = getenv("CDBDIRECT_LIB");
    const char *path = argv[1];
    const char *fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -";
    if (!lib || !path) {
        fprintf(stderr, "usage: CDBDIRECT_LIB=... %s <dump-path>\n", argv[0]);
        return 1;
    }
    void *h = dlopen(lib, RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    init_fn init = (init_fn)dlsym(h, "cdbdirect_initialize");
    get_fn get = (get_fn)dlsym(h, "cdbdirect_get");
    size_fn size = (size_fn)dlsym(h, "cdbdirect_size");
    fin_fn fin = (fin_fn)dlsym(h, "cdbdirect_finalize");
    if (!init || !get || !size || !fin) {
        fprintf(stderr, "missing symbols in %s\n", lib);
        return 1;
    }
    void *db = init(path);
    if (!db) { fprintf(stderr, "cdbdirect_initialize failed for %s\n", path); return 1; }
    size_t n = size(db);
    const char *resp = get(db, fen);
    printf("positions: %zu\n", n);
    printf("startpos:  %s\n", resp ? resp : "(miss)");
    fin(db);
    dlclose(h);
    return resp ? 0 : 2;
}
SMOKE_EOF

        info "Compiling smoke test..."
        gcc -O2 -o "$SMOKE_BIN" "$SMOKE_SRC" -ldl

        info "Probing start position at ${RESOLVED_DUMP}..."
        export LD_LIBRARY_PATH="${INSTALL_DIR}/lib:${LD_LIBRARY_PATH:-}"
        if CDBDIRECT_LIB="${CDB_SHARED}" "$SMOKE_BIN" "$RESOLVED_DUMP"; then
            ok "Smoke test passed"
        else
            rc=$?
            if [[ "$rc" -eq 2 ]]; then
                warn "Connected to DB but start position was not found (FEN key mismatch?)"
                warn "Check X-FEN canonicalization — see CDBDIRECT_SETUP.md"
            else
                die "Smoke test failed (exit ${rc}). Check dump path and LD_LIBRARY_PATH."
            fi
        fi
    fi
fi

section "Done"
ok "cdbdirect setup complete."
ok "TERARKDBROOT=${INSTALL_DIR}"
