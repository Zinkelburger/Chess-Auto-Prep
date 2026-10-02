#!/usr/bin/env python3
"""Embed the pinned Stockfish as a signed helper inside the macOS app bundle.

Xcode calls this after Flutter embeds its frameworks, before signing the app.
Sandboxed apps cannot execute the upstream engine with its original signature;
helpers must explicitly inherit the app's sandbox. Never re-sign at runtime.
"""
import gzip
import hashlib
import json
import os
import platform
from pathlib import Path
import struct
import subprocess


def network_layout(data):
    """Locate Stockfish 19's shared NNUE and Intel offset variable in Mach-O."""
    magic, count = struct.unpack_from('>II', data)
    if magic != 0xCAFEBABE or count != 2:
        raise RuntimeError('Expected the pinned two-slice universal Stockfish')
    slices = {}
    for index in range(count):
        cpu, _, offset, size, _ = struct.unpack_from('>5I', data, 8 + index * 20)
        if offset + size > len(data):
            raise RuntimeError('Truncated Stockfish slice')
        slices[cpu] = (offset, size)
    intel, intel_size = slices[0x01000007]
    arm, arm_size = slices[0x0100000C]
    thin = data[intel:intel + intel_size]
    header = struct.unpack_from('<8I', thin)
    if header[0] != 0xFEEDFACF:
        raise RuntimeError('Expected a 64-bit Intel Mach-O slice')
    segments = []
    symbols = None
    cursor = 32
    for _ in range(header[4]):
        command, size = struct.unpack_from('<II', thin, cursor)
        if size < 8 or cursor + size > 32 + header[5]:
            raise RuntimeError('Invalid Stockfish load command')
        if command == 0x19:  # LC_SEGMENT_64: virtual address → file offset
            _, address, _, file_offset, file_size = struct.unpack_from('<16s4Q', thin, cursor + 8)
            segments.append((address, file_offset, file_size))
        elif command == 2:  # LC_SYMTAB
            symbols = struct.unpack_from('<4I', thin, cursor + 8)
        cursor += size
    if symbols is None:
        raise RuntimeError('Stockfish has no symbol table for its shared network')
    table, count, strings, _ = symbols
    fields = {}
    for index in range(count):
        name, _, _, _, address = struct.unpack_from('<IBBHQ', thin, table + index * 16)
        start = strings + name
        symbol = thin[start:thin.index(b'\0', start)]
        if symbol not in (b'_gUniversalNNUEOffset', b'_gUniversalNNUESize'):
            continue
        for base, offset, size in segments:
            if base <= address and address + 8 <= base + size:
                fields[symbol] = intel + offset + address - base
                break
    pointer = fields[b'_gUniversalNNUEOffset']
    size = struct.unpack_from('<Q', data, fields[b'_gUniversalNNUESize'])[0]
    return arm, arm_size, pointer, size


def repair_network_offset(original, signed):
    """Rebase the Intel absolute file offset when codesign repacks fat slices.

    The upstream src/universal/nnue_embed.cpp maps network bytes from the
    arm64 slice. codesign can move that slice without updating this pointer.
    Validate every network byte against the pinned input before changing it.
    """
    old_arm, old_arm_size, old_pointer, size = network_layout(original)
    old_offset = struct.unpack_from('<Q', original, old_pointer)[0]
    arm, arm_size, pointer, signed_size = network_layout(signed)
    relative = old_offset - old_arm
    if size == 0 or relative < 0 or relative + size > min(old_arm_size, arm_size) or size != signed_size:
        raise RuntimeError('Invalid embedded Stockfish network range')
    offset = arm + relative
    if signed[offset:offset + size] != original[old_offset:old_offset + size]:
        raise RuntimeError('Signing changed the pinned Stockfish network bytes')
    if struct.unpack_from('<Q', signed, pointer)[0] == offset:
        return signed
    repaired = bytearray(signed)
    struct.pack_into('<Q', repaired, pointer, offset)
    return bytes(repaired)


def main():
    root = Path(__file__).resolve().parent.parent
    asset = root / 'assets/executables/stockfish-macos.gz'
    engine = gzip.decompress(asset.read_bytes())
    lock = json.loads((root / 'tools/assets.lock.json').read_text())
    # The engine is checked, not its gzip container, whose bytes depend on the
    # zlib of whichever machine packed it. Both macOS entries pin the same
    # universal binary; the check follows the architectures Xcode builds
    # (ARCHS), not the machine it runs on: an Apple Silicon runner builds the
    # Intel app too.
    host = 'arm64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x86_64'
    archs = os.environ.get('ARCHS', '').split() or [host]
    expected = {lock[f'stockfish-macos-{arch}']['payload_sha256']
                for arch in archs if f'stockfish-macos-{arch}' in lock}
    if hashlib.sha256(engine).hexdigest() not in expected:
        raise RuntimeError(
            f'The macOS Stockfish does not match assets.lock.json for {" ".join(archs)}')
    contents = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['CONTENTS_FOLDER_PATH']
    helper = contents / 'Helpers/stockfish-macos'
    helper.parent.mkdir(parents=True, exist_ok=True)
    helper.write_bytes(engine)
    helper.chmod(0o755)
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
    sign = [
        '/usr/bin/codesign', '--force', '--sign', identity,
        '--entitlements', str(root / 'macos/Runner/Engine.entitlements'),
        str(helper),
    ]
    subprocess.run(sign, check=True)
    signed = helper.read_bytes()
    repaired = repair_network_offset(engine, signed)
    if repaired != signed:
        print('Rebasing the Intel Stockfish network offset after codesign repacked the universal binary')
        helper.write_bytes(repaired)
        # Patching invalidates the Intel signature. Sign again with the same
        # metadata, and refuse a signer that moves the network a second time.
        subprocess.run(sign, check=True)
        signed = helper.read_bytes()
        if repair_network_offset(engine, signed) != signed:
            raise RuntimeError('Stockfish network offset did not stabilize after signing')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(helper)], check=True)


if __name__ == '__main__':
    main()
