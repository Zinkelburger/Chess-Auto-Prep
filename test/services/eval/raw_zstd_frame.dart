/// A zstd frame carrying [content] in a single *raw* (stored) block.
///
/// Hand-built rather than produced by a compressor so the eval tests are
/// deterministic and need no `zstd` binary to create their fixtures: magic, a
/// single-segment frame header with a four-byte content size, then one
/// last-block header and the bytes themselves.  Raw blocks cap at 128 KB,
/// which is far more than any fixture here needs.
library;

import 'dart:typed_data';

Uint8List rawZstdFrame(List<int> content) {
  assert(content.length < 1 << 17, 'one raw block holds at most 128 KB');
  final header = ByteData(4)..setUint32(0, content.length, Endian.little);
  final blockHeader = (content.length << 3) | 1; // last block, raw type
  return Uint8List.fromList([
    0x28, 0xB5, 0x2F, 0xFD, // magic
    0xA0, // single segment, 4-byte content size
    ...header.buffer.asUint8List(),
    blockHeader & 0xff,
    (blockHeader >> 8) & 0xff,
    (blockHeader >> 16) & 0xff,
    ...content,
  ]);
}
