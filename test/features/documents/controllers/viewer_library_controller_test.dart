import 'dart:async';

import 'package:chess_auto_prep/features/documents/controllers/viewer_library_controller.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_library_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'viewer_session_controller_test.dart' show MemoryPreferences;

class _Preferences extends MemoryPreferences {
  final recentWrites = <List<String>>[];
  List<String> stored = [];
  Completer<void>? recentGate;
  bool failRecent = false;

  @override
  Future<void> saveRecentFiles(List<String> paths) async {
    recentWrites.add(paths);
    await recentGate?.future;
    if (failRecent) throw StateError('preferences unavailable');
    stored = List.of(paths);
  }
}

class _Library implements PgnLibraryRepository {
  bool fail = false;
  @override
  Future<bool> exists(String path) async => true;
  @override
  Future<String> collectionsDirectory() async {
    if (fail) throw StateError('library unavailable');
    return '/collections';
  }

  @override
  String parentDirectory(String path) => '/collections';
}

void main() {
  test(
    'recent writes retain request order and published membership is immutable',
    () async {
      final preferences = _Preferences()..recentGate = Completer<void>();
      final owner = ViewerLibraryController(
        library: _Library(),
        preferences: preferences,
        isActive: () => true,
      );
      addTearDown(owner.dispose);
      final first = owner.addToRecentFiles('/a.pgn');
      final second = owner.addToRecentFiles('/b.pgn');
      await Future<void>.delayed(Duration.zero);
      expect(preferences.recentWrites, [
        ['/a.pgn'],
      ]);
      expect(owner.recentFiles, ['/b.pgn', '/a.pgn']);
      expect(() => owner.recentFiles.clear(), throwsUnsupportedError);
      preferences.recentGate!.complete();
      await Future.wait([first, second]);
      expect(preferences.stored, ['/b.pgn', '/a.pgn']);
      expect(owner.errorMessage, isNull);
    },
  );

  test(
    'retry clears only its own error and a failed write does not poison the queue',
    () async {
      final preferences = _Preferences()..failRecent = true;
      final library = _Library()..fail = true;
      final owner = ViewerLibraryController(
        library: library,
        preferences: preferences,
        isActive: () => true,
      );
      addTearDown(owner.dispose);
      await owner.loadCollections();
      await owner.addToRecentFiles('/a.pgn');
      expect(owner.errorMessage, contains('save recent'));
      preferences.failRecent = false;
      await owner.addToRecentFiles('/b.pgn');
      expect(preferences.stored, ['/b.pgn', '/a.pgn']);
      expect(owner.errorMessage, contains('locate'));
      library.fail = false;
      await owner.loadCollections();
      expect(owner.errorMessage, isNull);
    },
  );
}
