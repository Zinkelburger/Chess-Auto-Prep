# Windows Hivemind runtime

The Windows executable is built from Hivemind revision
`5508ba9daf4164e48a8a8a9b39e101efdc60e97a` at
https://github.com/Zinkelburger/hivemind plus `engine.patch` and `ort_loader.h`.
The patch disables implicit ONNX initialization and Windows import-library
linking. The engine loads `hivemind_ort.dll` by absolute Unicode path relative
to its own executable, uses the returned module handle for `OrtGetApiBase`,
checks the loaded path and API compatibility, and initializes the C++ wrapper
before creating any ONNX objects. Errors reach stderr and exit normally.
The Windows entry point preserves Unicode arguments and enables UTF-8 path
conversions while retaining the C numeric locale for UCI.
There is no fallback to `onnxruntime.dll`, PATH, or the current directory.

The runtime bytes remain Microsoft's pinned 1.29.0 build. Only its installed
filename changes. Existing `onnxruntime.dll` files are not deleted: other
features may own them. The app's existing hash verification repairs missing,
old or corrupt managed files before launch. This fixes the observed API 29 /
ORT 1.17.1 mismatch without assuming which Windows loader rule caused it.

`hivemind-windows.exe.gz`, `hivemind-source.tar.gz`, the tiny test DLL and
`build.json` are committed together, like the browser engine. App builds need
no cross compiler. `fetch_assets.py` checks the executable and build-source
hashes before installing it; changes require a rebuild. The complete modified
engine source is included in the source archive (Hivemind MIT and embedded
Fairy-Stockfish GPL-3.0 notices retained). The adapter is part of Chess Auto
Prep under AGPL-3.0. Release packaging includes the corresponding source archive.

## Rebuild on Linux

Use Python 3.12+, CMake and Ninja. Download these into the ignored directory
`build/bughouse-windows-deps/`:

* `llvm-mingw-20260908-ucrt-ubuntu-22.04-x86_64.tar.xz` from
  https://github.com/mstorsjo/llvm-mingw/releases/tag/20260908
  (SHA-256 `2258c745e3155870c80793f3e8c80b28fbde11b9ff73c4c78783635b3440b092`).
  Extract it there without changing the directory name.
* The ONNX Runtime Windows SDK in `inputs.json`, saved as `ort.zip`.

Clone https://github.com/Zinkelburger/hivemind (or use an existing checkout
containing the pinned revision). The builder reads that revision with
`git archive`; it does not edit the checkout or include its working changes.

```sh
scripts/ci.sh with -- python3 tools/bughouse_windows/build.py --source /path/to/hivemind
python3 tools/fetch_assets.py --only bughouse-windows --force
```

The engine uses the baseline x86-64 instruction set and static C++ runtime.
Commit the rebuilt files, metadata and updated `tools/assets.lock.json`.
For an extracted corresponding-source archive, compile its `engine/` using
the CMake arguments in `build-instructions/build.py`; the loader patch is
already applied. Supply the SDK and compiler above.

## Verification

`test_windows_ort_loading.py` tests the shipped executable with a deliberately
incompatible 1.17.1 API fixture, a missing private DLL, and a full network search
while an incompatible `onnxruntime.dll` is beside the executable. Every native
Windows release runs this check. On Linux `--wine` uses a disposable Wine
prefix; this supplements, but cannot replace, native Windows validation.
