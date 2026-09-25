import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_config.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/tree_wire_v4.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/file_lock.dart';
import 'package:dartchess/dartchess.dart' show Chess, Side;
import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/integrity_report.dart';
import 'package:chess_auto_prep/v2/storage/profile_integrity.dart';
import 'package:chess_auto_prep/v2/storage/training_writes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _before = '[Event "Course"]\n[ChapterName "First"]\n\n1. e4 *\n';
const _after = '[Event "Course"]\n[ChapterName "Second"]\n\n1. e4 *\n';

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late File course;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('profile-integrity-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    course = File(p.join(documents.path, 'repertoires', 'Course.pgn'));
    await course.parent.create();
    await course.writeAsString(_before);
  });
  tearDown(() => root.delete(recursive: true));

  Future<IntegrityReport> inspect({
    Directory? configured,
    Directory? metadata,
  }) async {
    final before = await _inventory(root);
    final report = await ProfileIntegrity(
      documents: configured ?? documents,
      support: metadata ?? support,
    ).read();
    expect(
      await _inventory(root),
      before,
      reason:
          'a diagnostic cannot recover or mutate profile bytes or membership',
    );
    return report;
  }

  test(
    'Support equal to a match directory does not reenter its held lock',
    () async {
      final match = _match();
      final shared = Directory(
        p.join(documents.path, 'bughouse_matches', match.id),
      );
      await shared.create(recursive: true);
      await File(
        p.join(shared.path, 'match.json'),
      ).writeAsString(jsonEncode(match.toJson()));
      await File(
        p.join(shared.path, 'games.bpgn'),
      ).writeAsString(matchBpgn(match));
      final report = await inspect(
        metadata: shared,
      ).timeout(const Duration(seconds: 2));
      expect(report.clean, isTrue);
    },
  );

  test(
    'Support equal to the domain is refused before nested acquisition',
    () async {
      final domain = Directory(
        p.join(documents.path, 'repertoires', '.cap-directory-domain'),
      );
      await domain.create();
      final report = await inspect(
        metadata: domain,
      ).timeout(const Duration(seconds: 2));
      expect(report.clean, isFalse);
      expect(report.findings.single.kind, IntegrityKind.unavailable);
    },
  );

  test(
    'domain linked to Documents is refused before nested acquisition',
    () async {
      await Link(
        p.join(documents.path, 'repertoires', '.cap-directory-domain'),
      ).create(documents.path);
      final report = await inspect().timeout(const Duration(seconds: 2));
      expect(report.clean, isFalse);
      expect(report.findings.single.kind, IntegrityKind.unavailable);
    },
    skip: Platform.isWindows,
  );

  test(
    'absent Support and repertoire roots are not created by inspection',
    () async {
      await course.parent.delete(recursive: true);
      await support.delete();
      expect((await inspect()).clean, isTrue);
      expect(await course.parent.exists(), isFalse);
      expect(await support.exists(), isFalse);
    },
  );

  test(
    'linked recovery namespace is refused without following or changing it',
    () async {
      final outside = await Directory(p.join(root.path, 'outside')).create();
      await File(p.join(outside.path, 'keep.json')).writeAsString('preserve');
      await Link(p.join(support.path, 'training-writes')).create(outside.path);
      final report = await inspect();
      expect(report.clean, isFalse);
      expect(report.skipped, isNotEmpty);
      expect(
        report.findings.any(
          (finding) => finding.path.endsWith('training-writes'),
        ),
        isTrue,
      );
    },
    skip: Platform.isWindows,
  );

  test('cancelled inspection stops without scanning artifacts', () async {
    final report = await ProfileIntegrity(
      documents: documents,
      support: support,
    ).read(isCancelled: () => true);
    expect(report.checked, isEmpty);
    expect(report.skipped.single, contains('cancelled'));
  });

  test(
    'unrelated links are ignored but artifact links are diagnosed',
    () async {
      await Link(
        p.join(documents.path, 'personal-link'),
      ).create('/unavailable');
      expect((await inspect()).clean, isTrue);
      final link = Link(p.join(course.parent.path, '.cap-generation'));
      await link.create('/unavailable');
      expect((await inspect()).findings.single.path, link.path);
    },
    skip: Platform.isWindows,
  );

  test(
    'unrelated unreadable folders do not create artifact findings',
    () async {
      final unrelated = await Directory(
        p.join(documents.path, 'private'),
      ).create();
      await Process.run('chmod', ['000', unrelated.path]);
      try {
        final report = await ProfileIntegrity(
          documents: documents,
          support: support,
        ).read();
        expect(report.clean, isTrue);
      } finally {
        await Process.run('chmod', ['700', unrelated.path]);
      }
    },
    skip: Platform.isWindows,
  );

  test('native BOM book and settings files remain valid', () async {
    await File(p.join(support.path, 'settings.json')).writeAsString('\ufeff{}');
    await File(
      p.join(support.path, 'books.json'),
    ).writeAsString('\ufeff${BookList.empty.encode()}');
    expect((await inspect()).clean, isTrue);
  });

  test(
    'malformed startup settings are reported with safe diagnostics',
    () async {
      final settings = File(p.join(support.path, 'settings.json'));
      await settings.writeAsString('private-settings-sentinel not JSON');
      final report = await inspect();
      expect(report.clean, isFalse);
      expect(report.findings.single.path, settings.path);
      expect(report.findings.single.detail, contains('Saved settings'));
      expect(
        report.findings.single.detail,
        isNot(contains('private-settings-sentinel')),
      );
    },
  );

  for (final name in ['settings.json', 'books.json']) {
    test('retained $name stage remains visible and unchanged', () async {
      final stage = File(temporaryPathFor(p.join(support.path, name)));
      await stage.writeAsString('uncertain publication');
      final report = await inspect();
      expect(report.findings.single.kind, IntegrityKind.unfinished);
      expect(report.findings.single.path, stage.path);
    });
  }

  test(
    'healthy empty metadata is inspected without creating journals',
    () async {
      final report = await inspect();
      expect(report.clean, isTrue);
      expect(report.checked, contains('Legacy operation compatibility'));
      expect(report.checked, contains('Book references'));
    },
  );

  for (final step in [
    CompoundWriteStep.prepared,
    CompoundWriteStep.intent,
    CompoundWriteStep.document,
  ]) {
    test(
      'compound ${step.name} stays unfinished without replay or cancellation',
      () async {
        final engine = CompoundWrites(
          documents: documents,
          support: support,
          testHook: (at) async {
            if (at == step) throw StateError('interruption');
          },
        );
        await expectLater(
          engine.commit(
            CompoundCommit(
              id: 'rename',
              documentPath: course.path,
              documentBefore: _before,
              documentAfter: _after,
              booksBefore: null,
              booksAfter: null,
            ),
          ),
          throwsStateError,
        );
        final report = await inspect();
        expect(
          report.findings.any((item) => item.kind == IntegrityKind.unfinished),
          isTrue,
        );
        expect(report.skipped, isNotEmpty);
        expect(report.checked, isNot(contains('Book references')));
        final again = await inspect();
        expect(again.clean, isFalse);
      },
    );
  }

  test(
    'queued training acceptance is diagnosed without writing participant rows',
    () async {
      await TrainingWrites(documents: documents, support: support).enqueue(
        id: 'accepted',
        payload: '["write",[],[],[]]',
        sources: const {},
      );
      final report = await inspect();
      expect(
        report.findings.any(
          (item) =>
              item.detail.contains('Training operations remain unfinished'),
        ),
        isTrue,
      );
      expect(
        await File(
          p.join(documents.path, 'repertoire_review_history.csv'),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'unknown malformed protocol metadata is preserved and dependents skipped',
    () async {
      final note = File(
        p.join(support.path, 'relocation-writes', 'unknown.json'),
      );
      await note.parent.create();
      await note.writeAsString('{"version":999,"preserve":"yes"}');
      final report = await inspect();
      expect(report.clean, isFalse);
      expect(
        report.findings.any((item) => item.kind == IntegrityKind.unavailable),
        isTrue,
      );
      expect(report.skipped, isNotEmpty);
    },
  );

  test(
    'completed native receipts stay valid history without requiring old PGN bytes',
    () async {
      await CompoundWrites(documents: documents, support: support).commit(
        CompoundCommit(
          id: 'completed',
          documentPath: course.path,
          documentBefore: _before,
          documentAfter: _after,
          booksBefore: null,
          booksAfter: null,
        ),
      );
      await course.writeAsString('later intentional edit');
      expect((await inspect()).clean, isTrue);
    },
  );

  test(
    'dangling file, section and active selectors are all reported',
    () async {
      final raw = {
        'version': 1,
        'active': 'missing',
        'books': [
          {
            'id': 'one',
            'name': 'My book',
            'repertoires': <String>[],
            'chapters': [
              {'path': 'Course.pgn', 'section': 'Gone'},
              {'path': 'missing.pgn', 'section': null},
            ],
          },
        ],
      };
      await File(
        p.join(support.path, 'books.json'),
      ).writeAsString(jsonEncode(raw));
      final report = await inspect();
      expect(
        report.findings.where((item) => item.kind == IntegrityKind.dangling),
        hasLength(3),
      );
    },
  );

  test(
    'a valid explicit section and preserved quarantine PGN are not dangling',
    () async {
      final deleted = File(
        p.join(course.parent.path, '.cap-recovery', 'old.pgn'),
      );
      await deleted.parent.create();
      await deleted.writeAsString(_before);
      final books = BookList(
        books: [
          Book(
            id: 'one',
            name: 'Book',
            chapters: {
              const BookChapter('Course.pgn', 'First'),
              const BookChapter('.cap-recovery/old.pgn', null),
            },
          ),
        ],
      );
      await File(
        p.join(support.path, 'books.json'),
      ).writeAsString(books.encode());
      expect((await inspect()).clean, isTrue);
    },
  );

  test(
    'malformed book selectors cannot be silently dropped into a clean report',
    () async {
      await File(p.join(support.path, 'books.json')).writeAsString(
        '{"version":1,"books":[{"id":"one","name":"Book","chapters":[{"path":42}]}]}',
      );
      final report = await inspect();
      expect(
        report.findings.any(
          (item) => item.detail.contains('Books could not be checked'),
        ),
        isTrue,
      );
    },
  );

  test(
    'unknown generated tree version is reported without rewriting it',
    () async {
      final tree = File(
        p.join(
          course.parent.path,
          '.cap-generation',
          'Course.pgn',
          'run',
          'tree.json',
        ),
      );
      await tree.parent.create(recursive: true);
      await tree.writeAsString(
        '{"format":"opening_tree","version":999,"tree":{},"config":{}}',
      );
      final report = await inspect();
      expect(
        report.findings.any(
          (item) =>
              item.kind == IntegrityKind.unsupported && item.path == tree.path,
        ),
        isTrue,
      );
    },
  );

  test(
    'missing selector parents are dangling rather than unreadable',
    () async {
      final books = BookList(
        books: [
          Book(
            id: 'one',
            name: 'Book',
            chapters: {const BookChapter('missing/nested/old.pgn', null)},
          ),
        ],
      );
      await File(
        p.join(support.path, 'books.json'),
      ).writeAsString(books.encode());
      final report = await inspect();
      expect(report.findings.single.kind, IntegrityKind.dangling);
    },
  );

  test('malformed source bodies are never included in diagnostics', () async {
    const secret = 'private-content-sentinel';
    await File(
      p.join(support.path, 'books.json'),
    ).writeAsString('$secret not JSON');
    final note = File(p.join(support.path, 'compound-writes', 'broken.json'));
    await note.parent.create();
    await note.writeAsString('$secret not JSON');
    final report = await inspect();
    expect(report.clean, isFalse);
    expect(
      report.findings.map((item) => item.detail).join(),
      isNot(contains(secret)),
    );
  });

  test(
    'known v4 study artifacts are format checked without freshness claim',
    () async {
      final tree = File(
        p.join(
          documents.path,
          'studies',
          '.cap-generation',
          'Study.pgn',
          'run',
          'tree.json',
        ),
      );
      await tree.parent.create(recursive: true);
      await tree.writeAsString(
        encodeTreeV4(
          HorizonNode(fen: Fen(Chess.initial.fen), evalForUs: null),
          const SearchConfig(side: Side.white),
          complete: true,
        ),
      );
      final report = await inspect();
      expect(report.clean, isTrue);
      expect(
        report.checked.any(
          (item) => item.contains('source freshness is not recorded'),
        ),
        isTrue,
      );
      await tree.writeAsString('private-content-sentinel not JSON');
      final broken = await inspect();
      expect(broken.findings.single.path, tree.path);
      expect(
        broken.findings.single.detail,
        isNot(contains('private-content-sentinel')),
      );
    },
  );

  test('blocked artifact root is diagnosed without removal', () async {
    final blocked = File(p.join(course.parent.path, '.cap-generation'));
    await blocked.writeAsString('preserve this obstruction');
    final report = await inspect();
    expect(report.findings.single.path, blocked.path);
    expect(report.findings.single.kind, IntegrityKind.unavailable);
  });

  test('BPGN mismatch is reported without invoking match repair', () async {
    final match = _match();
    final folder = Directory(
      p.join(documents.path, 'bughouse_matches', match.id),
    );
    await folder.create(recursive: true);
    await File(
      p.join(folder.path, 'match.json'),
    ).writeAsString(jsonEncode(match.toJson()));
    final report = await inspect();
    expect(report.findings.single.kind, IntegrityKind.derived);
    final export = File(p.join(folder.path, 'games.bpgn'));
    expect(await export.exists(), isFalse);
    await export.writeAsString(matchBpgn(match));
    expect((await inspect()).clean, isTrue);
    await export.writeAsString('wrong derived export');
    expect((await inspect()).findings.single.kind, IntegrityKind.derived);
  });

  for (final name in ['match.json', 'games.bpgn']) {
    test(
      'retained $name stage is diagnosed even when committed bytes agree',
      () async {
        final match = _match();
        final folder = Directory(
          p.join(documents.path, 'bughouse_matches', match.id),
        );
        await folder.create(recursive: true);
        await File(
          p.join(folder.path, 'match.json'),
        ).writeAsString(jsonEncode(match.toJson()));
        await File(
          p.join(folder.path, 'games.bpgn'),
        ).writeAsString(matchBpgn(match));
        final stage = File(temporaryPathFor(p.join(folder.path, name)));
        await stage.writeAsString('retained uncertain publication');
        final report = await inspect();
        expect(report.findings.single.kind, IntegrityKind.unfinished);
        expect(report.findings.single.path, stage.path);
      },
    );
  }

  test(
    'inspection completes while all shared mutation locks are held',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final domain = Directory(
        p.join(documents.path, 'repertoires', '.cap-directory-domain'),
      );
      final holding = withDirectoryLock(
        domain,
        () => withDirectoryLock(
          documents,
          () => withDirectoryLock(support, () async {
            entered.complete();
            await release.future;
          }),
        ),
      );

      await entered.future;
      try {
        expect(
          (await inspect().timeout(const Duration(seconds: 2))).clean,
          isTrue,
        );
      } finally {
        release.complete();
        await holding;
      }
    },
  );

  test(
    'missing profile roots are reported without creating directories',
    () async {
      final missing = Directory(p.join(root.path, 'absent'));
      final report = await inspect(configured: missing);
      expect(report.clean, isFalse);
      expect(await missing.exists(), isFalse);
    },
  );

  test('same Documents and Support lock is deduplicated', () async {
    expect(
      (await inspect(
        metadata: documents,
      ).timeout(const Duration(seconds: 5))).clean,
      isTrue,
    );
  });

  test(
    'configured root alias is allowed; linked children are not followed',
    () async {
      final alias = Link(p.join(root.path, 'alias'));
      await alias.create(documents.path);
      expect((await inspect(configured: Directory(alias.path))).clean, isTrue);
      final target = File(p.join(root.path, 'external.json'));
      await target.writeAsString('preserve');
      await Link(p.join(support.path, 'books.json')).create(target.path);
      final report = await inspect(configured: Directory(alias.path));
      expect(
        report.findings.any((item) => item.kind == IntegrityKind.unavailable),
        isTrue,
      );
    },
    skip: Platform.isWindows,
  );
}

Future<Map<String, String>> _inventory(Directory root) async {
  final result = <String, String>{};
  await for (final entry in root.list(recursive: true, followLinks: false)) {
    final name = p.relative(entry.path, from: root.path);
    result[name] = switch (entry) {
      File() => base64Encode(await entry.readAsBytes()),
      Link() => 'link:${await entry.target()}',
      _ => 'directory',
    };
  }
  return result;
}

StoredMatch _match() => StoredMatch(
  id: 'one',
  createdAt: DateTime(2026),
  status: MatchStatus.completed,
  config: const MatchConfig(
    name: 'Saved match',
    seed: 7,
    startDualFen:
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1|'
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1',
  ),
  games: [
    (
      number: 1,
      whiteIndex: 0,
      blackIndex: 1,
      whiteName: 'Hivemind A',
      blackName: 'Hivemind B',
      result: MatchResult.whiteWins,
      ending: MatchEnding.checkmate,
      detail: 'board 2',
      moves: ['1e2e4', '2d2d4'],
      startedAt: DateTime(2026),
      durationMs: 10,
    ),
  ],
);
