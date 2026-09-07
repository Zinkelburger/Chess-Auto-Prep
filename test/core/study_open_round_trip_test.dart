/// Opening a study file goes through an isolate and re-adopts every chapter
/// on the way back; nothing the file said may be lost in that hop.
library;

import 'dart:io';

import 'package:chess_auto_prep/core/study_controller.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

const _study = '''
[Event "Openings: For Black"]
[StudyName "Openings"]
[ChapterName "For Black"]
[Orientation "black"]
[ECO "B90"]

{ Play the Najdorf. } 1. e4 c5 2. Nf3 d6 *

[Event "Openings: For White"]
[StudyName "Openings"]
[ChapterName "For White"]
[Orientation "white"]

1. d4 *
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String path;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('study_open_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    StorageFactory.instanceForTest = null;
    path = await StorageFactory.instance.studyFilePath('Openings');
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(_study);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('openStudy keeps chapter names, orientation, intro and tags', () async {
    final study = StudyController();
    await study.openStudy(path);

    expect(study.doc.chapters.map((c) => c.name), ['For Black', 'For White']);
    expect(study.chapter.orientation, Side.black);
    expect(study.flipped, isTrue, reason: 'the board faces Black at once');
    expect(study.tree.rootComment, 'Play the Najdorf.');
    expect(study.chapter.headers['ECO'], 'B90');

    study.selectChapter(1);
    expect(study.flipped, isFalse);

    // What goes back to disk is the same Lichess-style chapter set.
    expect(study.chapterPgn(0), contains('[ChapterName "For Black"]'));
    expect(study.chapterPgn(0), contains('[Orientation "black"]'));
    expect(p.basename(study.doc.filePath!), 'Openings.pgn');
    study.dispose();
  });
}
