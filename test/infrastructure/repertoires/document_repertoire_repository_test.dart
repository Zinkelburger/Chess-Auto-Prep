import 'dart:async';

import 'package:chess_auto_prep/chess_core/pgn/repertoire_document_mutation.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_document_store.dart';

const first = '[Event "First"]\n[LineID "one"]\n[Custom "keep"]\n\n1. e4 e5 *';
const second = '[Event "Second"]\n[LineID "two"]\n\n1. d4 d5 *';
const content = '// Color: White\n\n$first\n\n$second\n';

void main() {
  late Store store;
  late DocumentRepertoireRepository repository;
  setUp(() {
    store = Store()..current = snapshot(content);
    repository = DocumentRepertoireRepository(store);
  });

  test('read distinguishes missing, empty and failed documents', () async {
    store.onOpen = (_) async => const PgnMissing();
    expect(await repository.read('/main.pgn'), (exists: false, pgn: null));
    store.current = snapshot('');
    store.onOpen = null;
    expect(await repository.read('/main.pgn'), (exists: true, pgn: ''));
    store.onOpen = (_) async => PgnReadFailed(StateError('read failed'));
    await expectLater(repository.read('/main.pgn'), throwsStateError);
  });

  test(
    'append captures intent and returns steps from the observed file',
    () async {
      final opened = Completer<PgnOpenResult>();
      store.onOpen = (_) => opened.future;
      final prefix = ['e4', 'e5'];
      final moves = ['Nf3', 'Nc6'];
      final operation = repository.append('/main.pgn', prefix, moves);
      prefix.clear();
      moves.clear();
      final before = snapshot(
        content.replaceFirst('e5 *', 'e5 {external before} *'),
      );
      store.current = before;
      opened.complete(PgnOpened(before));
      final receipt = await operation;
      expect(receipt.steps, hasLength(2));
      receipt.validate(requestedPath: ['e4', 'e5', 'Nf3', 'Nc6']);
      expect(receipt.previousContent, before.content);
      expect(receipt.updatedContent, contains('{external before}'));
      expect(receipt.updatedContent, contains(second));
      expect(store.saves.single, same(before));
      expect(() => receipt.steps.clear(), throwsUnsupportedError);
    },
  );

  test(
    'append conflicts after observation without returning an undo receipt',
    () async {
      store.onSave = (before, next) async {
        store.current = snapshot('$content\n{external}', revision: 'external');
        return PgnConflict(store.current);
      };
      await expectLater(
        repository.append('/main.pgn', ['e4', 'e5'], ['Nf3']),
        throwsA(isA<AtomicWriteConflict>()),
      );
      expect(store.saves, hasLength(1));
      expect(store.current.content, endsWith('{external}'));
    },
  );

  test(
    'line edit keeps unrelated external changes and returns merged headers',
    () async {
      final other = second.replaceFirst('d5', 'd5 {external other game}');
      store.current = snapshot('// Preserve banner\n\n$first\n\n$other\n');
      final saved = await repository.updateLineContent(
        '/main.pgn',
        'one',
        '[Event "Edited"]\n\n1. e4 e5 {mine} *',
        expectedContent: first,
      );
      expect(saved, contains('[LineID "one"]'));
      expect(saved, contains('[Custom "keep"]'));
      expect(store.current.content, startsWith('// Preserve banner'));
      expect(store.current.content, contains(other));
      expect(saved, splitRepertoireDocument(store.current.content).games.first);
      final next = await repository.updateLineContent(
        '/main.pgn',
        'one',
        saved!.replaceFirst('{mine}', '{next}'),
        expectedContent: saved,
      );
      expect(next, contains('{next}'));
    },
  );

  test(
    'line edits and deletion reject a changed target before any write',
    () async {
      store.current = snapshot(content.replaceFirst('e5', 'e5 {external}'));
      await expectLater(
        repository.updateLineContent(
          '/main.pgn',
          'one',
          first,
          expectedContent: first,
        ),
        throwsA(isA<AtomicWriteConflict>()),
      );
      await expectLater(
        repository.deleteLine('/main.pgn', 'one', expectedContent: first),
        throwsA(isA<AtomicWriteConflict>()),
      );
      expect(store.saves, isEmpty);
      expect(store.current.content, contains('{external}'));
    },
  );

  test(
    'bulk deletion validates all captured positions before changing any',
    () async {
      store.current = snapshot('$second\n\n$first\n');
      await expectLater(
        repository.deleteLinesAt('/main.pgn', {0: first}),
        throwsA(isA<AtomicWriteConflict>()),
      );
      expect(store.saves, isEmpty);
      store.current = snapshot(content);
      expect(await repository.deleteLinesAt('/main.pgn', {0: first}), 1);
      expect(store.current.content, contains(second));
      expect(store.current.content, isNot(contains('[Event "First"]')));
    },
  );

  test(
    'structural edits retain the exact bound game when its derived id changes',
    () async {
      const game = '[Event "No explicit ID"]\n\n1. e4 e5 *';
      store.current = snapshot(game);
      final id = lineIdsForGames([game]).single!;
      final saved = await repository.updateLineContent(
        '/main.pgn',
        id,
        game.replaceFirst('e5 *', 'e5 2. Nf3 *'),
        expectedContent: game,
      );
      final next = await repository.updateLineContent(
        '/main.pgn',
        id,
        saved!.replaceFirst('Nf3', 'Nf3 {later edit}'),
        expectedContent: saved,
      );
      expect(next, contains('{later edit}'));
      expect(store.saves, hasLength(2));
      store.current = snapshot('$next\n\n$next');
      await expectLater(
        repository.updateLineContent(
          '/main.pgn',
          id,
          game,
          expectedContent: next!,
        ),
        throwsA(isA<AtomicWriteConflict>()),
      );
      expect(store.saves, hasLength(2));
    },
  );

  test('a line edit cannot publish multiple games', () async {
    await expectLater(
      repository.updateLineContent(
        '/main.pgn',
        'one',
        '$first\n\n$second',
        expectedContent: first,
      ),
      throwsFormatException,
    );
    expect(store.saves, isEmpty);
    expect(store.current.content, content);
  });

  test('replace never adopts a newer expectation for an undo', () async {
    await expectLater(
      repository.replace('/main.pgn', 'old', expectedContent: 'stale'),
      throwsA(isA<AtomicWriteConflict>()),
    );
    expect(store.saves, isEmpty);
    await repository.replace('/main.pgn', first, expectedContent: content);
    expect(store.current.content, first);
  });

  test(
    'uncertain append is not retried; undo reconciles only its exact result',
    () async {
      store.onSave = (before, next) async {
        store.current = snapshot(next, revision: 'installed');
        return PgnWriteUncertain(
          error: StateError('ack lost'),
          before: before,
          observed: store.current,
        );
      };
      await expectLater(
        repository.append('/main.pgn', ['e4', 'e5'], ['Nf3']),
        throwsStateError,
      );
      expect(store.saves, hasLength(1));
      final appended = store.current.content;
      await repository.replace(
        '/main.pgn',
        content,
        expectedContent: appended,
        reconcileInstalled: true,
      );
      expect(store.current.content, content);
      store.onSave = (before, next) async {
        store.current = snapshot('unrelated', revision: 'other');
        return PgnWriteUncertain(
          error: StateError('ack lost'),
          before: before,
          observed: snapshot(next),
        );
      };
      await expectLater(
        repository.replace(
          '/main.pgn',
          first,
          expectedContent: content,
          reconcileInstalled: true,
        ),
        throwsStateError,
      );
      expect(store.current.content, 'unrelated');
    },
  );
}
