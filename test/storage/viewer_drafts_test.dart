import 'dart:io';

import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/recovery_quarantine.dart';
import 'package:chess_auto_prep/storage/viewer_drafts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory support;
  setUp(() => support = Directory.systemTemp.createTempSync('viewer-drafts'));
  tearDown(() => support.deleteSync(recursive: true));

  const draft = ViewerDraft(
    path: '/Documents/pgn_collections/games.pgn',
    game: 2,
    revision: Revision('ab12'),
    text: '[Event "x"]\n\n1. e4 {kept} *\n',
  );

  List<FileSystemEntity> quarantined() {
    final folder = Directory(p.join(support.path, quarantineFolder));
    return folder.existsSync()
        ? folder.listSync(recursive: true).whereType<File>().toList()
        : const [];
  }

  test('a kept draft is found by another instance, as it was', () async {
    await ViewerDraftFiles(support).keep(draft);
    final found = await ViewerDraftFiles(support).find(draft.path);
    expect(found!.text, draft.text);
    expect(found.game, 2);
    expect(found.revision, draft.revision);
    expect(await ViewerDraftFiles(support).find('/other.pgn'), isNull);
  });

  test(
    'a dropped draft is gone; one set aside is kept in quarantine',
    () async {
      final drafts = ViewerDraftFiles(support);
      await drafts.keep(draft);
      await drafts.drop(draft.path);
      expect(await drafts.find(draft.path), isNull);
      await drafts.keep(draft);
      await drafts.setAside(draft.path);
      expect(await drafts.find(draft.path), isNull);
      expect(quarantined(), hasLength(1));
    },
  );

  test('a record of another version is set aside, not obeyed', () async {
    final drafts = ViewerDraftFiles(support);
    await drafts.keep(draft);
    final file = Directory(
      p.join(support.path, ViewerDraftFiles.folder),
    ).listSync().whereType<File>().single;
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst('"version":1', '"version":9'),
    );
    expect(await drafts.find(draft.path), isNull);
    expect(file.existsSync(), isFalse);
    expect(quarantined(), hasLength(1));
  });
}
