import 'dart:io';

import 'package:chess_auto_prep/storage/deleted_chapters.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory profile;
  late Directory root;
  late RecoveryGate recovery;

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('v2-studies-');
    root = await Directory(p.join(profile.path, 'studies')).create();
    recovery = RecoveryGate(
      documents: profile,
      support: Directory(p.join(profile.path, 'Support')),
    );
  });

  tearDown(() => profile.delete(recursive: true));

  test('studies with an upper-case .PGN extension are listed', () async {
    await File(p.join(root.path, 'Opening.PGN')).writeAsString('*');
    await File(p.join(root.path, 'endgames.pgn')).writeAsString('*');
    await File(p.join(root.path, 'notes.txt')).writeAsString('');
    final listed =
        await StudyDirectory(root, recovery: recovery).list() as StudiesListed;
    expect(listed.studies.map((s) => s.name), ['endgames', 'Opening']);
  });

  test('a link inside the deleted folder is not a deleted chapter', () async {
    final trash = await Directory(p.join(root.path, recoveryFolder)).create();
    final outside = File(p.join(profile.path, 'outside.pgn'))
      ..writeAsStringSync('*');
    await File(
      p.join(trash.path, '1700000000000000-ab12-Kept.pgn'),
    ).writeAsString('*');
    Link(
      p.join(trash.path, '1700000000000001-cd34-Linked.pgn'),
    ).createSync(outside.path);
    final listed =
        await StudyDirectory(root, recovery: recovery).deleted()
            as DeletedChapters;
    expect(listed.chapters.map((c) => c.name), ['Kept']);
  });
}
