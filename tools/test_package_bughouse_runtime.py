#!/usr/bin/env python3
"""Offline packaging regression checks, including setup's compressed payload."""
import gzip
import json
import struct
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import package_bughouse_runtime as runtime


def pe(machine=0x8664):
    data = bytearray(512)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 128)
    data[128:132] = b'PE\0\0'
    struct.pack_into('<H', data, 132, machine)
    struct.pack_into('<H', data, 152, 0x20b)
    return bytes(data)


def must_fail(fn, text):
    try:
        fn()
    except (ValueError, FileNotFoundError) as e:
        assert text in str(e), str(e)
    else:
        raise AssertionError(f'expected failure: {text}')


def main():
    with tempfile.TemporaryDirectory(prefix='bughouse-runtime-') as temp:
        bundle = Path(temp)
        must_fail(lambda: runtime.package(bundle), 'missing')
        for name in runtime.REQUIRED:
            (bundle / name).write_bytes(pe())
        (bundle / 'onnxruntime.dll').write_bytes(b'different unrelated runtime')
        runtime.package(bundle)
        archive = bundle / 'data' / 'bughouse-runtime'
        manifest = json.loads((archive / 'manifest.json').read_text())
        assert set(manifest) == runtime.REQUIRED
        # Setup removes/excludes loose DLLs. Archives must remain sufficient.
        for name in runtime.REQUIRED:
            (bundle / name).unlink()
        runtime.package(bundle, check=True)
        from test_bughouse_engine import install_windows_runtime
        target = bundle / 'engine'
        target.mkdir()
        assert set(install_windows_runtime(bundle, target)) == runtime.REQUIRED
        assert all((target / name).read_bytes() == pe() for name in runtime.REQUIRED)
        name = sorted(runtime.REQUIRED)[0]
        (archive / f'{name}.gz').write_bytes(gzip.compress(pe() + b'corruption'))
        must_fail(lambda: runtime.package(bundle, check=True), 'mismatch')
        for name in runtime.REQUIRED:
            (bundle / name).write_bytes(pe())
        (bundle / name).write_bytes(pe(0x14c))
        must_fail(lambda: runtime.package(bundle), 'expected x64')
        (bundle / name).write_bytes(b'broken PE file')
        must_fail(lambda: runtime.package(bundle), 'DOS header')
    # Exercise the actual CMake install hook, including a destination with
    # spaces, without compiling the Windows app on this host.
    repo = Path(__file__).resolve().parent.parent
    if shutil.which('cmake'):
        with tempfile.TemporaryDirectory(prefix='runtime cmake ') as temp:
            root = Path(temp)
            bundle = root / 'app bundle'
            bundle.mkdir()
            for name in runtime.REQUIRED:
                (bundle / name).write_bytes(pe())
            hook = (repo / 'windows' / 'CMakeLists.txt').read_text().split(
                '# Keep verified, compressed VC++ copies', 1
            )[1]
            hook = '# Keep verified, compressed VC++ copies' + hook
            hook = hook.replace('${CMAKE_CURRENT_SOURCE_DIR}/..', repo.as_posix())
            hook = hook.replace('find_program(BUGHOUSE_PYTHON NAMES python3 python)',
                                f'set(BUGHOUSE_PYTHON "{Path(sys.executable).as_posix()}")')
            # The test supplies synthetic DLLs; force the same branch used
            # whenever Windows bughouse assets are present in a build.
            condition = next(line for line in hook.splitlines() if line.startswith('if(EXISTS'))
            hook = hook.replace(condition, 'if(TRUE)', 1)
            (root / 'CMakeLists.txt').write_text(
                'cmake_minimum_required(VERSION 3.14)\nproject(runtime_test NONE)\n'
                'add_executable(runtime_app IMPORTED)\n'
                f'set_target_properties(runtime_app PROPERTIES IMPORTED_LOCATION "{bundle.as_posix()}/app.exe")\n'
                'set(CMAKE_INSTALL_PREFIX "$<TARGET_FILE_DIR:runtime_app>" CACHE PATH "" FORCE)\n' + hook
            )
            subprocess.run(['cmake', '-S', str(root), '-B', str(root / 'build'),
                            f'-DCMAKE_INSTALL_PREFIX={bundle}'], check=True, capture_output=True)
            result = subprocess.run(['cmake', '--install', str(root / 'build')],
                                    capture_output=True, text=True)
            assert result.returncode == 0, result.stdout + result.stderr
            runtime.package(bundle, check=True)
    print('Private runtime packaging tests passed (including CMake install hook)')


if __name__ == '__main__':
    main()
