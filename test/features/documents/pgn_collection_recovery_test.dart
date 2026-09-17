import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/core/pgn/pgn_collection_helpers.dart';
import 'package:chess_auto_prep/features/documents/controllers/pgn_collection_editor.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_repository.dart';
import '../../support/scripted_document_store.dart';

const original = '[Event "Original"]\n\n1. e4 *';
const external = '[Event "External"]\n\n1. d4 *';

class Repository extends Store implements PgnCollectionRepository {
  Repository() {
    current = snapshot(original);
  }
  final recovered = <String>[];
  Future<void> Function()? onRecovery;
  @override
  Future<PgnWriteResult> patch(
    String path,
    Map<String, String> replacements,
  ) async => save(current, replacements.values.join('\n\n'));
  @override
  Future<String?> retainRecovery(String content) async {
    await onRecovery?.call();
    recovered.add(content);
    return '/retained.pgn';
  }

  @override
  Future<DateTime?> modified(String path) async => null;
}

class Fixture {
  final repository = Repository();
  var games = parseMultiGamePgn(original);
  String? path = '/main.pgn';
  late final PgnCollectionEditor editor;
  Future<void> Function()? decodeGate;
  Fixture() {
    editor = PgnCollectionEditor(
      repository: repository,
      path: () => path,
      games: () => games,
      collectionPreamble: () => '; My collection',
      selectedGame: () => games.first,
      onContentChanged: ({required resetIndex}) {},
      onSaved: (_) {},
      onSavedCopy: (value) => path = value,
      isActive: () => true,
      prepareReplacement: (content, destination) async {
        await decodeGate?.call();
        final parsed = parseMultiGamePgn(content);
        return () {
          games = parsed;
          path = destination;
          editor.adoptPersistedGames(games);
          editor.clearEditedGames();
          editor.clearScreenOnlyMovetext();
        };
      },
    );
    editor.adoptPersistedGames(games, baseline: repository.current);
    editor.setAutoSave(false);
  }
  void edit(String note) =>
      editor.persistMoveCommentsFor(games.first, '1. e4 {$note} *');
}

void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.editor.dispose());
  test(
    'exclusive copy keeps a collision unchanged and late edits dirty',
    () async {
      f.edit('draft');
      f.repository.onCreate = (_, _) async => const PgnNameCollision();
      expect(await f.editor.saveCopy('/occupied.pgn'), isA<PgnNameCollision>());
      expect(f.path, '/main.pgn');
      expect(f.editor.hasUnsavedChanges, isTrue);
      final gate = Completer<PgnWriteResult>();
      f.repository.onCreate = (_, _) => gate.future;
      final copy = f.editor.saveCopy('/copy.pgn');
      f.edit('later');
      expect(await f.editor.saveCopy('/second.pgn'), isNull);
      gate.complete(
        PgnSaved(before: null, after: snapshot('submitted', path: '/copy.pgn')),
      );
      await copy;
      expect(f.path, '/copy.pgn');
      expect(f.editor.hasUnsavedChanges, isTrue);
      expect(f.editor.state.baseline!.path, '/copy.pgn');
    },
  );
  test(
    'inspection does not adopt; reload retains the latest draft and blocks autosave',
    () async {
      f.edit('mine');
      f.repository.current = snapshot(external, revision: 'external');
      expect(await f.editor.inspectCurrent(), isA<PgnOpened>());
      expect(f.games.single.pgnText, contains('{mine}'));
      final gate = Completer<void>();
      f.decodeGate = () => gate.future;
      final reload = f.editor.reloadPreservingDraft();
      await Future<void>.delayed(Duration.zero);
      f.edit('late note');
      gate.complete();
      await reload;
      expect(f.games.single.pgnText, external);
      expect(
        f.editor.state.retainedDrafts.single.content,
        contains('{late note}'),
      );
      expect(f.repository.recovered.single, startsWith('; My collection'));
      f.editor.setAutoSave(true);
      f.edit('new edit');
      await f.editor.flushPendingMetadata();
      expect(f.repository.saves, isEmpty);
    },
  );
  test(
    'draft changing while its recovery is written vetoes reload without losing work',
    () async {
      f.edit('before');
      f.repository.current = snapshot(external);
      final gate = Completer<void>();
      f.repository.onRecovery = () => gate.future;
      final reload = f.editor.reloadPreservingDraft();
      await Future<void>.delayed(Duration.zero);
      f.edit('after');
      gate.complete();
      await reload;
      expect(f.games.single.pgnText, contains('{after}'));
      expect(
        f.editor.state.retainedDrafts.single.content,
        contains('{before}'),
      );
      expect(f.editor.state.readFailure, isA<PgnReadFailed>());
    },
  );
  test(
    'restored draft saves against the captured reload revision, never newer disk',
    () async {
      f.edit('mine');
      f.repository.current = snapshot(external, revision: 'external');
      await f.editor.reloadPreservingDraft();
      await f.editor.restoreDraft(0);
      expect(f.editor.hasUnsavedChanges, isTrue);
      expect(f.games.single.pgnText, contains('{mine}'));
      final reloaded = f.editor.state.baseline;
      f.repository.current = snapshot('$external\n{newer}', revision: 'newer');
      expect(await f.editor.save(), isA<PgnConflict>());
      expect(f.repository.saves.single, same(reloaded));
      expect(f.repository.current.content, contains('{newer}'));
    },
  );
  test(
    'failed recovery blocks reload and restoration of a retained draft',
    () async {
      f.edit('mine');
      f.repository.current = snapshot(external, revision: 'external');
      f.repository.onRecovery = () async => throw StateError('disk full');
      await f.editor.reloadPreservingDraft();
      expect(f.games.single.pgnText, contains('{mine}'));
      expect(f.editor.state.retainedDrafts, isEmpty);
      expect(f.editor.state.readFailure, isA<PgnReadFailed>());

      f.repository.onRecovery = null;
      await f.editor.reloadPreservingDraft();
      f.edit('displaced');
      f.repository.onRecovery = () async => throw StateError('disk full');
      await f.editor.restoreDraft(0);
      expect(f.games.single.pgnText, contains('{displaced}'));
      expect(f.editor.state.retainedDrafts.single.content, contains('{mine}'));
      expect(f.editor.state.readFailure, isA<PgnReadFailed>());

      f.repository.onRecovery = null;
      await f.editor.restoreDraft(0);
      expect(f.games.single.pgnText, contains('{mine}'));
      expect(
        f.editor.state.retainedDrafts.single.content,
        contains('{displaced}'),
      );
      expect(f.repository.recovered.last, contains('{displaced}'));
      expect(f.editor.state.readFailure, isNull);
    },
  );
  test(
    'restoration preserves an unannotated pasted collection before replacing it',
    () async {
      f.edit('retained');
      f.repository.current = snapshot(external);
      await f.editor.reloadPreservingDraft();
      f.games = parseMultiGamePgn(original);
      f.path = null;
      f.editor.adoptPersistedGames(f.games);
      f.editor.clearEditedGames();
      expect(f.editor.hasUnsavedChanges, isFalse);
      expect(f.editor.state.dirty, isTrue);
      await f.editor.restoreDraft(0);
      expect(f.games.single.pgnText, contains('{retained}'));
      expect(f.repository.recovered.last, contains(original));
      expect(f.editor.state.retainedDrafts.single.content, contains(original));
      expect(f.editor.state.retainedDrafts.single.path, isEmpty);
    },
  );
  test(
    'an uncertain original survives a colliding copy and a failed reload',
    () async {
      f.edit('mine');
      f.repository.onSave = (_, _) async => PgnWriteUncertain(
        error: StateError('ack'),
        before: null,
        observed: null,
      );
      await f.editor.save();
      f.repository.onCreate = (_, _) async => const PgnNameCollision();
      await f.editor.saveCopy('/occupied.pgn');
      expect(f.editor.state.uncertain, isTrue);
      expect(f.editor.state.inspectionPath, '/main.pgn');
      f.repository.onOpen = (_) async => const PgnMissing();
      await f.editor.reloadPreservingDraft();
      expect(f.editor.state.uncertain, isTrue);
      expect(f.games.single.pgnText, contains('{mine}'));
      expect(f.editor.state.readFailure, isA<PgnMissing>());
      expect(await f.editor.saveChanges(), isFalse);
    },
  );
}
