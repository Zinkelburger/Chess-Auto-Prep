import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chess_auto_prep/services/engine/stockfish_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lock key matches this OS', () {
    if (Platform.isLinux) {
      expect(stockfishLockKey(), 'stockfish-linux');
      expect(stockfishBinaryName(), 'stockfish-linux');
    } else if (Platform.isWindows) {
      expect(stockfishLockKey(), 'stockfish-windows');
      expect(stockfishBinaryName(), 'stockfish-windows.exe');
    } else if (Platform.isMacOS) {
      expect(stockfishBinaryName(), 'stockfish-macos');
      expect(
        stockfishLockKey(),
        anyOf('stockfish-macos-arm64', 'stockfish-macos-x86_64'),
      );
    }
  });

  test('largest zip member is the engine-sized file', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('docs/Copying.txt', [1, 2, 3]))
      ..addFile(ArchiveFile.bytes('stockfish/stockfish', List.filled(50, 7)));
    final zip = ZipEncoder().encode(archive);
    final got = stockfishLargestArchiveMember(
      Uint8List.fromList(zip),
      'https://example/stockfish-windows-x86-64.zip',
    );
    expect(got, List.filled(50, 7));
  });

  test('largest tar member is the engine-sized file', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('stockfish/README.md', [9]))
      ..addFile(
        ArchiveFile.bytes('stockfish/stockfish-linux', List.filled(40, 4)),
      );
    final tar = TarEncoder().encode(archive);
    final got = stockfishLargestArchiveMember(
      Uint8List.fromList(tar),
      'https://example/stockfish-ubuntu-x86-64.tar',
    );
    expect(got, List.filled(40, 4));
  });
}
