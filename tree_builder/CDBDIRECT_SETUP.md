# cdbdirect Setup Guide

**cdbdirect** probes a local copy of the [ChessDB](https://www.chessdb.cn/) TerarkDB snapshot (~50B positions, ~1TB). It is the fastest eval source in Chess-Auto-Prep’s chain when you have the full dump on disk—typically 5–20 ms per lookup on HDD vs. network API latency.

## System requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Disk (dump) | ~1 TB free | SSD for dump, or HDD with read-ahead + batch lookups |
| Disk (build) | ~5 GB for deps | Same |
| RAM | 8 GB | 16 GB+ (TerarkDB opens with a 1 GB page cache) |
| CPU | 4 cores | 8+ cores for faster TerarkDB compile |

**HDD vs SSD:** The dump works on a spinning HDD. Enable `--cdbdirect-read-ahead` and `--batch-eval-lookups` in the CLI (or the matching toggles in the Flutter UI). Expect ~5–20 ms/lookup on HDD vs. sub-ms on NVMe.

## Prerequisites

Install build tools and libraries, then run the setup script (or build manually below).

### Fedora / RHEL

```bash
sudo dnf install cmake gcc-c++ git make zlib-devel snappy-devel lz4-devel \
  bzip2-devel jemalloc-devel tbb-devel boost-devel
```

### Ubuntu / Debian

```bash
sudo apt install cmake g++ git make build-essential zlib1g-dev libsnappy-dev \
  liblz4-dev libbz2-dev libjemalloc-dev libtbb-dev libboost-fiber-dev autoconf
```

### Arch Linux

```bash
sudo pacman -S cmake gcc git make zlib snappy lz4 bzip2 jemalloc tbb boost
```

## Quick setup (recommended)

From `tree_builder/`:

```bash
make setup-cdbdirect
# or directly:
./scripts/setup_cdbdirect.sh --dump-path /mnt/hdd/chess-20251115/data
```

The script:

1. Checks for required packages (prints install commands if anything is missing)
2. Clones [noobpwnftw/terarkdb](https://github.com/noobpwnftw/terarkdb) and [vondele/cdbdirect](https://github.com/vondele/cdbdirect) into `deps/` (gitignored)
3. Builds TerarkDB with `-fPIC`, Release, no tests/tools
4. Builds `libcdbdirect.a` + `libcdbdirect.so` (C API wrapper for tree_builder and Flutter)
5. Installs everything under `deps/install/`
6. Prints `TERARKDBROOT` / `CHESSDB_PATH` lines for `~/.bashrc`
7. Runs a smoke test if `--dump-path` points at a valid dump

Add the printed exports to `~/.bashrc`, then:

```bash
source ~/.bashrc
```

Re-run safely anytime; use `--force` to rebuild from scratch.

## Manual build

If you prefer not to use the script:

```bash
cd tree_builder
mkdir -p deps && cd deps

# 1. TerarkDB
export CFLAGS="-fPIC $CFLAGS" CXXFLAGS="-fPIC $CXXFLAGS"
export EXTRA_CFLAGS="-fPIC" EXTRA_CXXFLAGS="-fPIC"
git clone --depth 1 https://github.com/noobpwnftw/terarkdb.git
cd terarkdb && git submodule update --init --recursive
WITH_TESTS=OFF WITH_TOOLS=OFF WITH_ZNS=OFF ./build.sh
cd ..

# 2. cdbdirect
git clone --depth 1 https://github.com/vondele/cdbdirect.git
cd cdbdirect
make lib -j"$(nproc)" \
  TERARKDBROOT="$PWD/../terarkdb" \
  CHESSDB_PATH="/mnt/hdd/chess-20251115/data"

# 3. C API wrapper + shared lib (see scripts/setup_cdbdirect.sh)
```

Copy headers/libs to a single prefix (e.g. `deps/install/`) and set `TERARKDBROOT` to that path.

## Build tree_builder with cdbdirect

```bash
cd tree_builder
export TERARKDBROOT="$PWD/deps/install"
export LD_LIBRARY_PATH="$TERARKDBROOT/lib:$LD_LIBRARY_PATH"

make HAS_CDBDIRECT=1 TERARKDBROOT="$TERARKDBROOT"
```

Binary: `bin/tree_builder`

Mock tests (no TerarkDB required):

```bash
make test-cdbdirect-mock
```

## Flutter app

1. Complete setup so `deps/install/lib/libcdbdirect.so` exists.
2. From the repo root: `./run_with_cdbdirect.sh` (sets `LD_LIBRARY_PATH` and `TERARKDBROOT` for dev runs).
3. In the app: **Repertoire → Actions → Database Downloads → Local ChessDB (full dump)**.
4. Browse to your dump’s **data** directory (folder containing `CURRENT` and `.sst` files).
5. On HDD: enable **HDD read-ahead hint** and **Batch eval lookups**.

The Dart provider loads `libcdbdirect.so` from the bundled app `lib/`, `LD_LIBRARY_PATH`, `TERARKDBROOT/lib`, or `tree_builder/deps/install/lib/` when run from the repo.

## CLI usage (HDD-optimized)

```bash
export TERARKDBROOT="$PWD/deps/install"
export LD_LIBRARY_PATH="$TERARKDBROOT/lib:$LD_LIBRARY_PATH"

./bin/tree_builder -c w -d 8 -e 16 -t 2 -v \
  --cdbdirect-path /mnt/hdd/chess-20251115/data \
  --cdbdirect-read-ahead \
  --batch-eval-lookups \
  --no-ext-eval-subtree-skip \
  my_repertoire
```

| Flag | Purpose |
|------|---------|
| `--cdbdirect-path` | TerarkDB data dir (often `.../data` inside the dump) |
| `--cdbdirect-read-ahead` | Sequential-access hint for HDD |
| `--batch-eval-lookups` | Sort/prefetch lookups per BFS level |
| `--no-ext-eval-subtree-skip` | Keep probing off-book lines (slower on HDD) |

## Downloading the ChessDB dump

The dump is ~1 TB. Pick one source:

### Hugging Face (recommended)

```bash
pip install huggingface_hub
hf download --repo-type dataset robertnurnberg/chessdbcn \
  --local-dir /mnt/hdd/chessdb --include "chess-20251115/**"
```

Data directory is typically `/mnt/hdd/chessdb/chess-20251115/data`.

### FTP (resumable, slower)

```bash
wget -c -r -nH --cut-dirs=2 --no-parent --reject="index.html*" \
  -e robots=off ftp://chessdb:chessdb@ftp.chessdb.cn/pub/chessdb/chess-20251115
```

### rclone (faster mirror)

Configure remote `chessdb` (FTP: `ftp.chessdb.cn`, user/pass `chessdb`), then:

```bash
rclone copy chessdb:/pub/chessdb/chess-20251115 /mnt/hdd/chess-20251115 \
  --transfers=10 --checkers=20 --multi-thread-streams=4 \
  --multi-thread-chunk-size=128M --progress \
  --exclude "index.html*"
```

### File descriptor limit

Large dumps may need a higher open-file limit:

```bash
ulimit -n 102400
```

Persist via `/etc/security/limits.conf` or systemd `LimitNOFILE=` if needed.

## Troubleshooting

### `libcdbdirect.so: cannot open shared object file`

```bash
export LD_LIBRARY_PATH="$TERARKDBROOT/lib:$LD_LIBRARY_PATH"
# or copy/symlink libcdbdirect.so to a directory already on LD_LIBRARY_PATH
ldd "$TERARKDBROOT/lib/libcdbdirect.so"   # check for missing deps
```

### Permission denied on dump path

Ensure your user can read the data directory and all `.sst` files. Avoid running the setup script with `sudo`; only install system packages with sudo.

### Build fails at TerarkDB

- Confirm all prerequisite `-devel` packages are installed.
- Ensure ~5 GB free under `tree_builder/deps/`.
- Re-run with `--force` after fixing packages.

### FEN not found / unexpected misses

cdbdirect expects strict [X-FEN](https://en.wikipedia.org/wiki/X-FEN): ep square `-` when no legal en passant, 4-field keys (move counters ignored). Chess-Auto-Prep canonicalizes FENs before lookup; if probes fail in external tools, compare against the project’s canonical form.

### Slow on HDD

- Enable read-ahead and batch lookups (see CLI example).
- Keep the dump on a dedicated disk if possible.
- Expect 5–20 ms/lookup; subtree skip (default) avoids probing deep off-book lines.

### Smoke test fails

- Verify `--dump-path` points at the directory containing `CURRENT` or `.../data`.
- Run `./scripts/setup_cdbdirect.sh --dump-path /your/path` after the download completes.
- Check `ulimit -n` if the DB opens but queries hang.

## Layout after setup

```
tree_builder/deps/
  terarkdb/          # upstream clone + output/
  cdbdirect/         # upstream clone + libcdbdirect.a
  install/
    include/         # TerarkDB + cdbdirect.h
    lib/
      libterarkdb.a
      libcdbdirect.a
      libcdbdirect.so   # Flutter FFI + runtime linking
```

Set `TERARKDBROOT` to `tree_builder/deps/install`.
