#!/usr/bin/env python3
"""Rebuild the checked-in Windows engine; run through scripts/ci.sh with --.

Linux cross-build with a pinned LLVM MinGW UCRT toolchain. Ordinary app builds
verify/copy the resulting small executable and fetch the unchanged pinned ORT
runtime; they do not need a second C++ toolchain.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REVISION = "5508ba9daf4164e48a8a8a9b39e101efdc60e97a"
TOOLCHAIN = "llvm-mingw-20260908-ucrt-ubuntu-22.04-x86_64"
TOOLCHAIN_SHA256 = "2258c745e3155870c80793f3e8c80b28fbde11b9ff73c4c78783635b3440b092"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True,
                        help="Hivemind checkout containing the pinned revision (never modified)")
    args = parser.parse_args()
    deps = ROOT / "build/bughouse-windows-deps"
    if digest(deps / (TOOLCHAIN + ".tar.xz")) != TOOLCHAIN_SHA256:
        raise SystemExit("Wrong LLVM MinGW archive; see README.md")
    inputs = json.loads((HERE / "inputs.json").read_text())
    if digest(deps / "ort.zip") != inputs["ort_sha256"]:
        raise SystemExit("Wrong ONNX Runtime SDK archive; see README.md")
    stage = ROOT / "build/bughouse-windows-source"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    archive = subprocess.check_output([
        "git", "-C", str(args.source), "archive", REVISION, "engine", "LICENSE"])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tf:
        tf.extractall(stage, filter="data")
    subprocess.run(["git", "apply", "--unidiff-zero", str(HERE / "engine.patch")], cwd=stage, check=True)
    shutil.copyfile(HERE / "ort_loader.h", stage / "engine/src/nn/ort_loader.h")
    shutil.copyfile(HERE / "windows_main.cc", stage / "engine/src/windows_main.cc")
    with zipfile.ZipFile(deps / "ort.zip") as zf:
        zf.extractall(deps / "ort")
    ort = deps / "ort/onnxruntime-win-x64-1.29.0"
    compiler = deps / TOOLCHAIN / "bin/x86_64-w64-mingw32-clang++"
    build = ROOT / "build/bughouse-windows-native"
    subprocess.run([
        "cmake", "-S", str(stage / "engine"), "-B", str(build), "-G", "Ninja",
        "-DCMAKE_SYSTEM_NAME=Windows", "-DCMAKE_SYSTEM_PROCESSOR=x86_64",
        f"-DCMAKE_CXX_COMPILER={compiler}",
        f"-DCMAKE_C_COMPILER={compiler.parent / 'x86_64-w64-mingw32-clang'}",
        "-DCMAKE_BUILD_TYPE=Release", "-DHIVEMIND_BACKEND=onnxruntime",
        f"-DONNXRuntime_ROOT={ort}", "-DHIVEMIND_NATIVE_ARCH=OFF",
        "-DHIVEMIND_ARCH=x86-64", "-DHIVEMIND_STATIC_CXX_RUNTIME=ON",
        "-DHIVEMIND_USE_CCACHE=OFF", "-DBUILD_TESTING=OFF",
        "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--no-insert-timestamp",
        f"-DCMAKE_CXX_FLAGS=-ffile-prefix-map={stage}=hivemind",
    ], check=True)
    subprocess.run(["cmake", "--build", str(build), "--parallel", "2"], check=True)
    exe = build / "hivemind.bin.exe"
    subprocess.run([str(compiler.parent / "llvm-strip"), str(exe)], check=True)
    fixture = build / "incompatible-runtime.dll"
    subprocess.run([str(compiler.parent / "x86_64-w64-mingw32-clang"),
                    "-shared", "-O2", "-Wl,--no-insert-timestamp", "-o", str(fixture),
                    str(HERE / "incompatible_runtime.c")], check=True)
    subprocess.run([str(compiler.parent / "llvm-strip"), str(fixture)], check=True)
    outputs = {}
    for name, path in [("hivemind-windows.exe.gz", exe),
                       ("incompatible-runtime.dll.gz", fixture)]:
        (HERE / name).write_bytes(gzip.compress(path.read_bytes(), mtime=0))
        outputs[name] = digest(HERE / name)
    # Complete corresponding engine source, including our loader changes.
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                info = tf.gettarinfo(path, arcname=str(path.relative_to(stage)))
                info.mtime = info.uid = info.gid = 0
                info.uname = info.gname = ""
                with path.open("rb") as fh:
                    tf.addfile(info, fh)
        for path in [HERE / "README.md", HERE / "build.py", HERE / "inputs.json",
                     HERE / "engine.patch", HERE / "ort_loader.h", HERE / "windows_main.cc", HERE / "incompatible_runtime.c",
                     ROOT / "LICENSE"]:
            data = path.read_bytes()
            info = tarfile.TarInfo("build-instructions/" + path.name)
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        toolchain = deps / TOOLCHAIN
        notices = [toolchain / "LICENSE.TXT"] + sorted(
            (toolchain / "x86_64-w64-mingw32/share/mingw32").glob("COPYING*"))
        for path in notices:
            data = path.read_bytes()
            info = tarfile.TarInfo("toolchain-notices/" + path.name)
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
    source_archive = HERE / "hivemind-source.tar.gz"
    source_archive.write_bytes(gzip.compress(buf.getvalue(), mtime=0))
    outputs[source_archive.name] = digest(source_archive)
    sources = {name: digest(HERE / name) for name in
               ["build.py", "engine.patch", "ort_loader.h", "windows_main.cc", "incompatible_runtime.c", "inputs.json", "README.md"]}
    (HERE / "build.json").write_text(json.dumps({
        "revision": REVISION, "toolchain": TOOLCHAIN,
        "compiler": subprocess.check_output([str(compiler), "--version"], text=True).splitlines()[0],
        "sha256": outputs, "source_sha256": sources,
        "engine_payload_sha256": digest(exe), "engine_bytes": exe.stat().st_size,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
