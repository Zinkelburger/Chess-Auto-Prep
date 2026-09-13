import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:flutter_test/flutter_test.dart';

class _SourceStorage extends IOStorageService {
  String content = '[Event "First"]\n\n1. e4 e5 *';
  @override
  Future<String?> readRepertoirePgn(String path) async => content;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cached trainer source picks up builder edits and training side changes',
    () async {
      final storage = _SourceStorage();
      StorageFactory.instanceForTest = storage;
      addTearDown(() => StorageFactory.instanceForTest = null);
      final service = RepertoireService();
      final first = await service.parseRepertoireFile(
        '/course.pgn',
        trainingColor: 'black',
      );
      final reopened = await service.parseRepertoireFile(
        '/course.pgn',
        trainingColor: 'black',
      );
      expect(identical(first.single, reopened.single), isTrue);
      reopened.clear();
      expect(
        (await service.parseRepertoireFile(
          '/course.pgn',
          trainingColor: 'black',
        )).single.color,
        'black',
      );
      final white = await service.parseRepertoireFile(
        '/course.pgn',
        trainingColor: 'white',
      );
      expect(white.single.color, 'white');
      storage.content = '[Event "Builder edit"]\n\n1. d4 d5 *';
      final edited = await service.parseRepertoireFile(
        '/course.pgn',
        trainingColor: 'white',
      );
      expect(edited.single.moves, ['d4', 'd5']);
      expect(edited.single.headers['Event'], 'Builder edit');
    },
  );
}
