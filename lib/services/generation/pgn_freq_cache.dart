/// Disk cache for parsed [PgnFreqMap] data.
///
/// Binary format mirrors C `pgn_freq_map_save` / `load` (magic `PFREQ\x01\x00\x00`).
/// Cache path: `<pgn-path>.freq.cache` alongside each PGN file.
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'pgn_freq_map.dart';

const _magic = 'PFREQ\x01\x00\x00';
const _fileVersion = 1;
const _fenKeyBytes = 128;
const _uciBytes = 8;
const _sanBytes = 16;

/// Build a JSON manifest keyed on file metadata and parse config.
String buildPgnFreqManifest({
  required String path,
  required io.FileStat stat,
  required PgnFreqConfig config,
}) {
  final manifest = <String, dynamic>{
    'format_version': 1,
    'start_fen': config.startFen,
    'start_moves': config.startMoves,
    'max_ply': config.maxPly,
    'min_elo': config.minElo,
    'files': [
      {
        'path': path,
        'size': stat.size,
        'mtime': stat.modified.millisecondsSinceEpoch,
      },
    ],
  };
  return jsonEncode(manifest);
}

String pgnFreqCachePath(String pgnPath) => '$pgnPath.freq.cache';

PgnFreqMap? loadPgnFreqCache(String cachePath, String expectedManifestJson) {
  io.File file;
  try {
    file = io.File(cachePath);
    if (!file.existsSync()) return null;
  } catch (_) {
    return null;
  }

  io.RandomAccessFile? raf;
  try {
    raf = file.openSync(mode: io.FileMode.read);

    final magic = raf.readSync(8);
    if (String.fromCharCodes(magic) != _magic) return null;

    final version = _readUint32(raf);
    if (version != _fileVersion) return null;

    final positionCount = _readUint64(raf);
    final totalGames = _readUint64(raf);
    final manifestLen = _readUint32(raf);

    final manifestBytes = raf.readSync(manifestLen);
    final manifest = utf8.decode(manifestBytes);
    if (manifest != expectedManifestJson) return null;

    final map = PgnFreqMap()..totalGames = totalGames;

    for (var pi = 0; pi < positionCount; pi++) {
      final fenKeyBytes = raf.readSync(_fenKeyBytes);
      final fenKey = utf8
          .decode(fenKeyBytes)
          .replaceAll('\x00', '')
          .trim();
      final reachCount = _readUint64(raf);
      final moveCount = _readUint32(raf);

      final pos = map.getOrCreate(fenKey);
      pos.reachCount = reachCount;

      for (var mi = 0; mi < moveCount; mi++) {
        final uciBytes = raf.readSync(_uciBytes);
        final sanBytes = raf.readSync(_sanBytes);
        final count = _readUint64(raf);

        final uci = utf8.decode(uciBytes).replaceAll('\x00', '').trim();
        final san = utf8.decode(sanBytes).replaceAll('\x00', '').trim();
        pos.moves.add(PgnFreqMove(uci: uci, san: san, count: count));
      }
    }

    return map;
  } catch (_) {
    return null;
  } finally {
    raf?.closeSync();
  }
}

bool savePgnFreqCache(
  PgnFreqMap map,
  String cachePath,
  String manifestJson,
) {
  io.RandomAccessFile? raf;
  try {
    final file = io.File(cachePath);
    raf = file.openSync(mode: io.FileMode.write);

    final manifestBytes = utf8.encode(manifestJson);
    raf.writeFromSync(_magic.codeUnits);

    final header = ByteData(24);
    header.setUint32(0, _fileVersion, Endian.little);
    header.setUint64(4, map.positionCount, Endian.little);
    header.setUint64(12, map.totalGames, Endian.little);
    header.setUint32(20, manifestBytes.length, Endian.little);
    raf.writeFromSync(header.buffer.asUint8List());
    raf.writeFromSync(manifestBytes);

    for (final entry in map.positions) {
      final pos = entry.value;
      raf.writeFromSync(_padUtf8(pos.fenKey, _fenKeyBytes));
      final posHeader = ByteData(16);
      posHeader.setUint64(0, pos.reachCount, Endian.little);
      posHeader.setUint32(8, pos.moves.length, Endian.little);
      raf.writeFromSync(posHeader.buffer.asUint8List());

      for (final move in pos.moves) {
        raf.writeFromSync(_padUtf8(move.uci, _uciBytes));
        raf.writeFromSync(_padUtf8(move.san, _sanBytes));
        final countBuf = ByteData(8);
        countBuf.setUint64(0, move.count, Endian.little);
        raf.writeFromSync(countBuf.buffer.asUint8List());
      }
    }

    return true;
  } catch (_) {
    try {
      io.File(cachePath).deleteSync();
    } catch (_) {}
    return false;
  } finally {
    raf?.closeSync();
  }
}

Uint8List _padUtf8(String s, int length) {
  final bytes = utf8.encode(s);
  final out = Uint8List(length);
  final n = bytes.length < length ? bytes.length : length;
  out.setRange(0, n, bytes.sublist(0, n));
  return out;
}

int _readUint32(io.RandomAccessFile raf) {
  final bytes = raf.readSync(4);
  return ByteData.sublistView(bytes).getUint32(0, Endian.little);
}

int _readUint64(io.RandomAccessFile raf) {
  final bytes = raf.readSync(8);
  return ByteData.sublistView(bytes).getUint64(0, Endian.little);
}
