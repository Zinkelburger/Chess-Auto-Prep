import 'dart:io';
import 'package:chess_auto_prep/v2/storage/pgn_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  setUp(
    () async => folder = await Directory.systemTemp.createTemp('pgn-export-'),
  );
  tearDown(() async => folder.delete(recursive: true));
  test(
    'export creates a UTF-8 snapshot and refuses all existing destinations',
    () async {
      final export = PgnExport(pickDirectory: () async => folder.path);
      const text = '[White "Réti"]\n\n1. Nf3 *\n';
      expect(await export.save('study.pgn', text), isA<PgnExported>());
      expect(
        await export.save('study.pgn', '1. e4 *\n'),
        isA<PgnExportFailed>(),
      );
      expect(await File(p.join(folder.path, 'study.pgn')).readAsString(), text);
    },
  );
  test('late target after the picker opens is not overwritten', () async {
    final export = PgnExport(
      pickDirectory: () async {
        await File(p.join(folder.path, 'study.pgn')).writeAsString('original');
        return folder.path;
      },
    );
    expect(await export.save('study.pgn', 'mine'), isA<PgnExportFailed>());
    expect(
      await File(p.join(folder.path, 'study.pgn')).readAsString(),
      'original',
    );
  });
  test('cancel and invalid name do not publish a file', () async {
    final export = PgnExport(pickDirectory: () async => null);
    expect(await export.save('study.pgn', 'mine'), isA<PgnExportCancelled>());
    expect(await export.save('../study.pgn', 'mine'), isA<PgnExportFailed>());
  });
}
