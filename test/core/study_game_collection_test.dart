import 'dart:io';
import 'package:chess_auto_prep/core/study_controller.dart';
import 'package:chess_auto_prep/models/study_document.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('study_selection');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    StorageFactory.instanceForTest = null;
  });
  tearDown(() async {
    StorageFactory.instanceForTest = null;
    await root.delete(recursive: true);
  });
  final game = StudyChapter.fromGameText(
    '[White "Alice"]\n[Black "Bob"]\n[Result "*"]\n\n1. e4 {note} e5 (1... c5) *',
    name: 'Same name',
  );

  test(
    'batch append preserves existing chapters, comments, branches, and repeated names',
    () async {
      final controller = StudyController();
      final path = await StorageFactory.instance.studyFilePath('Selected');
      expect(await controller.addChaptersToStudyFile(path, [game]), 0);
      expect(await controller.addChaptersToStudyFile(path, [game, game]), 1);
      final content = (await StorageFactory.instance.readFile(path))!;
      final restored = StudyDocument.fromPgn(content, name: 'Selected');
      expect(restored.chapters, hasLength(3));
      expect(restored.chapters.map((c) => c.name), everyElement('Same name'));
      expect(content, contains('note'));
      expect(content, contains('c5'));
      controller.dispose();
    },
  );

  test(
    'adding to open study retains unsaved edits and current chapter',
    () async {
      final controller = StudyController();
      await controller.newStudy('Open');
      controller.playSan('d4');
      final before = controller.chapter;
      final index = controller.chapterIndex;
      final path = controller.doc.filePath!;
      expect(await controller.addChaptersToStudyFile(path, [game, game]), 1);
      expect(controller.chapter, same(before));
      expect(controller.chapterIndex, index);
      final restored = StudyDocument.fromPgn(
        (await StorageFactory.instance.readFile(path))!,
        name: 'Open',
      );
      expect(restored.chapters, hasLength(3));
      expect(restored.chapters.first.toPgn(), contains('d4'));
      controller.dispose();
    },
  );
}
