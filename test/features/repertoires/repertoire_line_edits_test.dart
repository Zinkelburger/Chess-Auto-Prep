import 'dart:async';

import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_line_edits.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_document_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _Documents implements RepertoireDocumentRepository {
  final calls = <(String, String, String, String)>[];
  Future<String?> Function(String, String, String, String)? write;
  @override
  Future<String?> updateLineContent(
    String path,
    String lineId,
    String content, {
    required String expectedContent,
  }) async {
    calls.add((path, lineId, content, expectedContent));
    return write == null
        ? content
        : await write!(path, lineId, content, expectedContent);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  test('queued updates keep the newest draft and advance only from receipts', () async {
    final documents = _Documents();
    final writes = RepertoireLineEdits(documents);
    final originals = {'line': 'original'};
    final context = RepertoireLineEditContext('/a', originals);
    originals['line'] = 'caller mutation';
    final gate = Completer<String?>();
    documents.write = (_, _, content, _) =>
        content == 'first' ? gate.future : Future.value('stored second');
    final first = writes.save(context, 'line', 'first');
    final second = writes.save(context, 'line', 'second');
    expect(writes.drafts.single.content, 'second');
    expect(writes.drafts.single.original, 'original');
    expect(() => writes.drafts.clear(), throwsUnsupportedError);
    gate.complete('stored first');
    expect(await first, 'stored first');
    expect(await second, 'stored second');
    expect(documents.calls.map((call) => call.$4), ['original', 'stored first']);
    expect(writes.drafts, isEmpty);
    await writes.flush();
    await writes.save(context, 'line', 'third');
    expect(documents.calls.last.$4, 'stored second');
  });

  test('another line succeeding cannot erase a failed draft or approve close', () async {
    final documents = _Documents()
      ..write = (_, id, content, _) async {
        if (id == 'a') throw StateError('disk unavailable');
        return content;
      };
    final writes = RepertoireLineEdits(documents);
    final context = RepertoireLineEditContext('/a', {'a': 'old a', 'b': 'old b'});
    await expectLater(writes.save(context, 'a', 'new a'), throwsStateError);
    await writes.save(context, 'b', 'new b');
    expect(writes.drafts.single.content, 'new a');
    expect(writes.drafts.single.original, 'old a');
    expect(writes.drafts.single.error, isA<StateError>());
    await expectLater(writes.flush(), throwsStateError);
    await expectLater(writes.flush(), throwsStateError);
    documents.write = null;
    await writes.save(context, 'a', 'retried a');
    expect(documents.calls.last.$4, 'old a');
    await writes.flush();
  });

  test('equal path and line IDs from another load have independent authority', () async {
    final documents = _Documents()..write = (_, _, _, _) async => null;
    final writes = RepertoireLineEdits(documents);
    final old = RepertoireLineEditContext('/a', {'line': 'old'});
    final newer = RepertoireLineEditContext('/a', {'line': 'newer'});
    expect(await writes.save(old, 'line', 'failed old draft'), isNull);
    documents.write = null;
    await writes.save(newer, 'line', 'new content');
    expect(documents.calls.last.$4, 'newer');
    expect(writes.drafts.single.original, 'old');
    expect(writes.drafts.single.content, 'failed old draft');
    await expectLater(writes.flush(), throwsStateError);
  });

  test('flush includes writes queued while its first receipt is pending', () async {
    final documents = _Documents();
    final writes = RepertoireLineEdits(documents);
    final context = RepertoireLineEditContext('/a', {'line': 'original'});
    final firstGate = Completer<String?>();
    final secondGate = Completer<String?>();
    documents.write = (_, _, content, _) =>
        content == 'first' ? firstGate.future : secondGate.future;
    final first = writes.save(context, 'line', 'first');
    var closed = false;
    final close = writes.flush().then((_) => closed = true);
    final second = writes.save(context, 'line', 'second');
    firstGate.complete('first');
    await first;
    await pumpEventQueue();
    expect(closed, isFalse);
    secondGate.complete('second');
    await second;
    await close;
    expect(closed, isTrue);
  });

  test('binding cannot replace a loaded original', () async {
    final documents = _Documents();
    final writes = RepertoireLineEdits(documents);
    final context = RepertoireLineEditContext('/a', {'line': 'original'});
    writes.bind(context, 'line', 'fresh disk content');
    await writes.save(context, 'line', 'edited');
    expect(documents.calls.single.$4, 'original');
    expect(() => writes.save(context, 'missing', 'edit'), throwsStateError);
  });
}
