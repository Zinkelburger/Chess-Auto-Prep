import 'dart:async';
import 'package:chess_auto_prep/features/documents/models/viewer_session.dart';
import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Backend extends InMemorySharedPreferencesStore {
  _Backend() : super.empty();
  bool reject = false;
  bool throws = false;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (throws) throw StateError('preferences offline');
    if (reject) return false;
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (reject) return false;
    return super.remove(key);
  }
}

const session = ViewerSession(
  gameIndex: 2,
  gameKey: 'stable-key',
  ply: 15,
  sortMode: GameSortMode.dateDesc,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SharedPreferences.setMockInitialValues({}));
  SharedPreferencesViewerRepository repo() =>
      SharedPreferencesViewerRepository(SharedPreferences.getInstance);

  test(
    'reads existing keys and payloads without rewriting a collection',
    () async {
      const slice = SliceConfig(
        headerFilters: [
          HeaderFilterConfig(
            field: 'White',
            mode: MatchMode.contains,
            value: 'Reader',
          ),
        ],
      );
      SharedPreferences.setMockInitialValues({
        'pgn_viewer.last_file': '/books/course.pgn',
        'pgn_viewer.session:/books/course.pgn': session.encode(),
        'pgn_viewer_recent_files': ['/books/course.pgn'],
        'pgn_slice:/books/course.pgn': slice.toJsonString(),
        'pgn_viewer.auto_detect_openings': false,
      });
      final storage = repo();
      expect(await storage.lastFile(), '/books/course.pgn');
      expect(
        (await storage.loadSession('/books/course.pgn'))!.encode(),
        session.encode(),
      );
      expect(await storage.loadRecentFiles(), ['/books/course.pgn']);
      expect(
        (await storage.loadSlice('/books/course.pgn'))!.toJsonString(),
        slice.toJsonString(),
      );
      expect(await storage.autoDetectOpenings(), isFalse);
      await storage.closeSession();
      expect(await storage.lastFile(), isNull);
      expect(await storage.loadSession('/books/course.pgn'), isNotNull);
      await storage.saveSlice('/books/course.pgn', const SliceConfig.empty());
      expect(await storage.loadSlice('/books/course.pgn'), isNull);
    },
  );

  test(
    'false acknowledgement is an error and its cached value is never read back as saved',
    () async {
      final backend = _Backend();
      SharedPreferencesStorePlatform.instance = backend;
      final storage = repo();
      await storage.saveRecentFiles(['old.pgn']);
      backend.reject = true;
      await expectLater(
        storage.saveRecentFiles(['lost.pgn']),
        throwsStateError,
      );
      expect(await storage.loadRecentFiles(), ['old.pgn']);
      await expectLater(
        storage.saveSession('lost.pgn', session),
        throwsStateError,
      );
      expect(await storage.loadSession('lost.pgn'), isNull);
      expect(await storage.lastFile(), isNull);
      backend.reject = false;
      await storage.saveSession('saved.pgn', session);
      expect(await storage.lastFile(), 'saved.pgn');
      expect((await storage.loadSession('saved.pgn'))!.ply, 15);
    },
  );

  test(
    'throwing writes drain the queue and close failures remain retryable',
    () async {
      final backend = _Backend()..throws = true;
      SharedPreferencesStorePlatform.instance = backend;
      final storage = repo();
      await expectLater(
        storage.saveSession('saved.pgn', session),
        throwsStateError,
      );
      backend.throws = false;
      await storage.saveSession('saved.pgn', session);
      backend.reject = true;
      await expectLater(storage.closeSession(), throwsStateError);
      expect(await storage.lastFile(), 'saved.pgn');
      backend.reject = false;
      await storage.closeSession();
      expect(await storage.lastFile(), isNull);
    },
  );

  test(
    'queued recent files capture values before delayed plugin acquisition',
    () async {
      final plugin = await SharedPreferences.getInstance();
      final gate = Completer<SharedPreferences>();
      final storage = SharedPreferencesViewerRepository(() => gate.future);
      final paths = ['captured.pgn'];
      final saving = storage.saveRecentFiles(paths);
      paths.add('later.pgn');
      final reading = storage.loadRecentFiles();
      gate.complete(plugin);
      await saving;
      final restored = await reading;
      expect(restored, ['captured.pgn']);
      expect(() => restored.add('mutated.pgn'), throwsUnsupportedError);
    },
  );

  test('malformed legacy bookmarks do not prevent opening a file', () async {
    SharedPreferences.setMockInitialValues({
      'pgn_viewer.session:a.pgn': '{broken',
    });
    expect(await repo().loadSession('a.pgn'), isNull);
    expect(await repo().autoDetectOpenings(), isTrue);
  });
}
