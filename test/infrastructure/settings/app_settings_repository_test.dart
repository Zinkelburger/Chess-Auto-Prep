import 'dart:async';

import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:chess_auto_prep/features/settings/models/repertoire_books.dart';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemoryBooks implements RepertoireBooksPreferences {
  RepertoireBooks value = RepertoireBooks();
  int reads = 0;
  int writes = 0;
  bool readFails = false;
  bool writeFails = false;
  bool failAfterWrite = false;
  bool ignoreWrite = false;
  BookSide? failSide;
  Completer<void>? writeGate;
  final writing = Completer<void>();
  void Function(BookSide)? afterWrite;

  @override
  Future<RepertoireBooks> read() async {
    reads++;
    if (readFails) throw StateError('Read failure');
    return value;
  }

  @override
  Future<void> writeSide(BookSide side, List<String> paths) async {
    writes++;
    if (!writing.isCompleted) writing.complete();
    await writeGate?.future;
    if (writeFails || side == failSide) throw StateError('Write failure');
    if (!ignoreWrite) value = value.withSide(side, paths);
    afterWrite?.call(side);
    if (failAfterWrite) throw StateError('Acknowledgement failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an edit enqueued by a listener waits for the active write', () async {
    final disk = MemoryBooks()..writeGate = Completer<void>();
    final books = PersistedRepertoireBooks(disk);
    Future<void>? second;
    final listener = books.changes.listen((state) {
      if (state.phase == SettingsPhase.saving && second == null) {
        second = books.addPath(BookSide.black, '/B');
      }
    });
    addTearDown(listener.cancel);
    final first = books.addPath(BookSide.white, '/A');
    await disk.writing.future;
    expect(disk.writes, 1);
    disk.writeGate!.complete();
    await first;
    await second;
    expect(disk.value.white, ['/A']);
    expect(disk.value.black, ['/B']);
  });

  test(
    'concurrent panel edits apply to latest state and retain both colors',
    () async {
      final disk = MemoryBooks();
      final books = PersistedRepertoireBooks(disk);
      await Future.wait([
        books.addPath(BookSide.white, '/books/A'),
        books.addPath(BookSide.white, '/books/B'),
        books.addPath(BookSide.black, '/books/C'),
        books.removePath(BookSide.white, '/books/A'),
      ]);
      expect(disk.value.white, ['/books/B']);
      expect(disk.value.black, ['/books/C']);
      expect(books.state.committed, disk.value);
    },
  );

  test(
    'pending and failed writes never present a draft as committed',
    () async {
      final disk = MemoryBooks()
        ..writeGate = Completer<void>()
        ..writeFails = true;
      final books = PersistedRepertoireBooks(disk);
      await books.ensureLoaded();
      final operation = books.addPath(BookSide.white, '/books/A');
      final failure = expectLater(operation, throwsStateError);
      await disk.writing.future;
      expect(books.state.phase, SettingsPhase.saving);
      expect(books.state.committed!.white, isEmpty);
      expect(books.state.draft!.white, ['/books/A']);
      disk.writeGate!.complete();
      await failure;
      expect(books.state.phase, SettingsPhase.failed);
      expect(books.state.committed!.white, isEmpty);
      disk.writeFails = false;
      disk.value = RepertoireBooks(black: ['/books/OtherPanel']);
      await books.retry();
      expect(books.state.committed!.white, ['/books/A']);
      expect(books.state.committed!.black, ['/books/OtherPanel']);
    },
  );

  test(
    'a failed read is shared and a later explicit load can recover',
    () async {
      final disk = MemoryBooks()..readFails = true;
      final books = PersistedRepertoireBooks(disk);
      final first = books.ensureLoaded();
      expect(identical(first, books.ensureLoaded()), isTrue);
      await expectLater(first, throwsStateError);
      expect(books.state.committed, isNull);
      disk.readFails = false;
      await books.ensureLoaded();
      expect(books.state.phase, SettingsPhase.ready);
      expect(disk.reads, 2);
    },
  );

  test(
    'acknowledgement failure reobserves a real commit without replaying it',
    () async {
      final disk = MemoryBooks()..failAfterWrite = true;
      final books = PersistedRepertoireBooks(disk);
      await expectLater(
        books.addPath(BookSide.white, '/books/A'),
        throwsStateError,
      );
      expect(books.state.phase, SettingsPhase.failed);
      expect(books.state.committed!.white, ['/books/A']);
      disk.failAfterWrite = false;
      await books.retry();
      expect(disk.writes, 1);
      expect(books.state.phase, SettingsPhase.ready);
    },
  );

  test(
    'successful return without persisted values is a failed confirmation',
    () async {
      final disk = MemoryBooks()..ignoreWrite = true;
      final books = PersistedRepertoireBooks(disk);
      await expectLater(
        books.addPath(BookSide.white, '/books/A'),
        throwsStateError,
      );
      expect(books.state.committed!.white, isEmpty);
      expect(books.state.draft!.white, ['/books/A']);
    },
  );

  test(
    'unrelated external field edit during confirmation is preserved',
    () async {
      final disk = MemoryBooks();
      disk.afterWrite = (_) =>
          disk.value = disk.value.withSide(BookSide.black, ['/external']);
      final books = PersistedRepertoireBooks(disk);
      await books.addPath(BookSide.white, '/books/A');
      expect(disk.value.black, ['/external']);
      expect(disk.writes, 1);
    },
  );

  test(
    'relocation is component-aware, retryable after a partial two-key commit',
    () async {
      final disk = MemoryBooks()
        ..value = RepertoireBooks(
          white: ['/books/A', '/books/A/nested', '/books/A-other'],
          black: ['/books/A'],
        )
        ..failSide = BookSide.black;
      final books = PersistedRepertoireBooks(disk);
      await expectLater(
        books.relocate(from: '/books/A', to: '/books/B'),
        throwsStateError,
      );
      expect(books.state.committed!.white, [
        '/books/B',
        '/books/B/nested',
        '/books/A-other',
      ]);
      expect(books.state.committed!.black, ['/books/A']);
      disk.failSide = null;
      await books.retry();
      expect(books.state.committed!.black, ['/books/B']);
      expect(disk.writes, 3);
      final restarted = PersistedRepertoireBooks(disk);
      await restarted.ensureLoaded();
      expect(restarted.state.committed, books.state.committed);
    },
  );

  test(
    'input is captured, deduplicated, immutable and rejects invalid paths',
    () async {
      final disk = MemoryBooks();
      final books = PersistedRepertoireBooks(disk);
      final paths = ['/A', '/A'];
      final write = books.setPaths(BookSide.white, paths);
      paths.add('/late');
      await write;
      expect(books.state.committed!.white, ['/A']);
      expect(
        () => books.state.committed!.white.add('/bad'),
        throwsUnsupportedError,
      );
      await expectLater(books.addPath(BookSide.white, ''), throwsArgumentError);
      await expectLater(
        books.addPath(BookSide.white, '/A\u0000B'),
        throwsArgumentError,
      );
      expect(disk.writes, 1);
    },
  );

  test('legacy adapter observes only confirmed selection changes', () async {
    final disk = MemoryBooks()..writeFails = true;
    final books = PersistedRepertoireBooks(disk);
    final legacy = MyRepertoireSettings(repository: books);
    addTearDown(legacy.dispose);
    var notifications = 0;
    legacy.addListener(() => notifications++);
    await legacy.ensureLoaded();
    expect(notifications, 1);
    await expectLater(
      legacy.addPath(white: true, path: '/A'),
      throwsStateError,
    );
    expect(notifications, 1);
    expect(legacy.whitePaths, isEmpty);
    disk.writeFails = false;
    await books.retry();
    expect(legacy.whitePaths, ['/A']);
    expect(notifications, 2);
  });

  test(
    'existing keys survive reload and invalid legacy data is not overwritten',
    () async {
      SharedPreferences.setMockInitialValues({
        'my_repertoire_white_paths': ['/A', '/A'],
        'my_repertoire_black_paths': ['/B'],
      });
      final settings = SharedPreferencesAppSettingsRepository();
      await settings.repertoireBooks.ensureLoaded();
      expect(settings.repertoireBooks.state.committed!.white, ['/A']);
      await settings.repertoireBooks.addPath(BookSide.white, '/C');
      final restarted = SharedPreferencesAppSettingsRepository();
      await restarted.repertoireBooks.ensureLoaded();
      expect(restarted.repertoireBooks.state.committed!.white, ['/A', '/C']);
      expect(restarted.repertoireBooks.state.committed!.black, ['/B']);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('my_repertoire_white_paths', 'malformed');
      await expectLater(
        restarted.repertoireBooks.addPath(BookSide.black, '/D'),
        throwsFormatException,
      );
      expect(prefs.getString('my_repertoire_white_paths'), 'malformed');
      expect(prefs.getStringList('my_repertoire_black_paths'), ['/B']);
    },
  );

  test('book subscribers receive the confirmed section state', () async {
    final disk = MemoryBooks();
    final settings = SharedPreferencesAppSettingsRepository(books: disk);
    await settings.repertoireBooks.ensureLoaded();
    final states = <Object>[];
    final subscription = settings.repertoireBooks.changes.listen(states.add);
    await settings.repertoireBooks.addPath(BookSide.black, '/B');
    expect(settings.repertoireBooks.state.committed!.black, ['/B']);
    expect(states, isNotEmpty);
    await subscription.cancel();
  });
}
