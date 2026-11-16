import 'dart:io';

import 'package:chess_auto_prep/storage/recovery_files.dart';
import 'package:chess_auto_prep/storage/relocation_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _refused = throwsA(isA<RecoveryRequired>());

void main() {
  final documents = Directory('/home/u/Documents');
  final support = Directory('/home/u/Documents/Support');
  String under(String relative) => p.join(documents.path, relative);

  test('a chapter cannot be moved onto itself', () {
    final path = under('repertoires/KID/Main.pgn');
    expect(() => validateRelocationPaths(documents, path, path), _refused);
  });

  group('a folder move', () {
    test('cannot go into its own parent\'s place', () {
      expect(
        () => validateFolderRelocationPaths(
          documents,
          under('repertoires/KID/Old'),
          under('repertoires/KID'),
        ),
        _refused,
      );
    });

    test('needs absolute, normalized paths even inside Documents', () {
      final relative = Directory(p.join(Directory.current.path, 'Documents'));
      expect(
        () => validateFolderRelocationPaths(
          relative,
          'Documents/repertoires/KID',
          p.join(relative.path, 'repertoires/Kings Indian'),
        ),
        _refused,
      );
      expect(
        () => validateFolderRelocationPaths(
          documents,
          under('repertoires/Old/../KID'),
          under('repertoires/Kings Indian'),
        ),
        _refused,
      );
    });

    test('cannot take the reference history with it, wherever Support is', () {
      expect(
        () => validateFolderParticipantPaths(
          documents,
          Directory('/home/u/.local/share/chess-prep'),
          documents.path,
          '/home/u/Old Documents',
        ),
        _refused,
      );
    });

    test('cannot take a recovery folder with it', () {
      expect(
        () => validateFolderParticipantPaths(
          documents,
          support,
          p.join(support.path, 'backups'),
          under('repertoires/backups'),
        ),
        _refused,
      );
    });
  });
}
