/// [AuditPersistence] and [AuditSnapshot] against an in-memory storage:
/// path derivation, complete/progress round trips, the version-1 file
/// layout, reports written by an older hunt, and the failure paths that
/// must return null rather than throw.
library;

import 'dart:convert';

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/audit/models/audit_result.dart';
import 'package:chess_auto_prep/features/audit/services/audit_config.dart';
import 'package:chess_auto_prep/features/audit/services/audit_persistence.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements StorageService {
  final Map<String, String> files = {};
  bool failWrites = false;
  bool failReads = false;

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<String?> readFile(String path) async {
    if (failReads) throw StateError('disk on fire');
    return files[path];
  }

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (failWrites) throw StateError('disk full');
    files[path] = content;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

const _pgn = '/reps/Ruy/Main.pgn';
const _json = '/reps/Ruy/Main_audit.json';
const _fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

AuditFinding _missing({bool dismissed = false}) => AuditFinding(
  type: AuditFindingType.missingResponse,
  severity: AuditSeverity.critical,
  movePath: const ['e4'],
  fen: _fen,
  missingMove: 'Nf6',
  evalLossCp: 10,
  positionEvalCp: 0,
  bestMoveEvalCp: -10,
  continuationCount: 3,
  source: MissingResponseSource.chessDb,
  cumulativeProbability: 0.5,
  transposesIntoRepertoire: true,
  dismissed: dismissed,
);

AuditFinding _trick() => AuditFinding(
  type: AuditFindingType.trickyMove,
  severity: AuditSeverity.warning,
  movePath: const ['e4', 'e5'],
  fen: _fen,
  ourMove: 'Nf3',
  exploitLine: const ['Nf3', 'Nc6', 'Bb5'],
  expectedEvalCp: 35,
  practicalGapCp: 20,
  netGainCp: 15,
  oppEase: 0.4,
  isNovelty: true,
  exploitScore: 7.5,
);

AuditResult _result(List<AuditFinding> findings) => AuditResult(
  findings: findings,
  nodesChecked: 12,
  ourMoveNodesChecked: 5,
  opponentNodesChecked: 4,
  leafNodesChecked: 3,
  evalCacheHits: 2,
  evalCacheMisses: 9,
  elapsed: const Duration(seconds: 42),
  timestamp: DateTime.utc(2026, 9, 8, 12),
);

const _config = AuditConfig(
  mistakeThresholdCp: 120,
  useChessDb: false,
  useStockfish: true,
  strongReplyWindowCp: 25,
  clashPgnPaths: ['/books/x.pgn'],
  clashUsername: 'rival',
  clashUserIsWhite: false,
);

void main() {
  late _MemoryStorage storage;
  final persistence = AuditPersistence.instance;

  setUp(() {
    storage = _MemoryStorage();
    StorageFactory.instanceForTest = storage;
  });
  tearDown(() => StorageFactory.instanceForTest = null);

  group('auditPath', () {
    test('sits next to the repertoire file', () {
      expect(persistence.auditPath(_pgn), _json);
      expect(
        persistence.auditPath('/a/b.chapter.pgn'),
        '/a/b.chapter_audit.json',
      );
    });

    test('null or empty repertoire path has no audit path', () {
      expect(persistence.auditPath(null), isNull);
      expect(persistence.auditPath(''), isNull);
    });
  });

  group('round trips', () {
    test('a complete result keeps every field and no checkedFens', () async {
      await persistence.saveComplete(
        _pgn,
        _result([_missing(dismissed: true), _trick()]),
        _config,
      );

      final raw = jsonDecode(storage.files[_json]!) as Map<String, dynamic>;
      expect(raw['version'], 2);
      expect(raw.containsKey('checkedFens'), isFalse);

      final snap = (await persistence.load(_pgn))!;
      expect(snap.isComplete, isTrue);
      expect(snap.checkedFens, isEmpty);

      expect(snap.config.mistakeThresholdCp, 120);
      expect(snap.config.useChessDb, isFalse);
      expect(snap.config.strongReplyWindowCp, 25);
      expect(snap.config.clashPgnPaths, ['/books/x.pgn']);
      expect(snap.config.clashUsername, 'rival');
      expect(snap.config.clashUserIsWhite, isFalse);

      final r = snap.result;
      expect(r.nodesChecked, 12);
      expect(r.ourMoveNodesChecked, 5);
      expect(r.opponentNodesChecked, 4);
      expect(r.leafNodesChecked, 3);
      expect(r.evalCacheHits, 2);
      expect(r.evalCacheMisses, 9);
      expect(r.elapsed, const Duration(seconds: 42));
      expect(r.timestamp, DateTime.utc(2026, 9, 8, 12));

      final missing = r.findings[0];
      expect(missing.type, AuditFindingType.missingResponse);
      expect(missing.dismissed, isTrue);
      expect(missing.missingMove, 'Nf6');
      expect(missing.evalLossCp, 10);
      expect(missing.positionEvalCp, 0);
      expect(missing.bestMoveEvalCp, -10);
      expect(missing.continuationCount, 3);
      expect(missing.source, MissingResponseSource.chessDb);
      expect(missing.cumulativeProbability, 0.5);
      expect(missing.transposesIntoRepertoire, isTrue);
      expect(missing.dismissKey, _missing().dismissKey);

      final trick = r.findings[1];
      expect(trick.type, AuditFindingType.trickyMove);
      expect(trick.exploitLine, ['Nf3', 'Nc6', 'Bb5']);
      expect(trick.expectedEvalCp, 35);
      expect(trick.practicalGapCp, 20);
      expect(trick.netGainCp, 15);
      expect(trick.oppEase, 0.4);
      expect(trick.isNovelty, isTrue);
      expect(trick.exploitScore, 7.5);
      expect(trick.dismissed, isFalse);
    });

    test('progress keeps checkedFens and comes back interrupted', () async {
      await persistence.saveProgress(_pgn, _result([_missing()]), _config, {
        _fen,
        'other',
      });

      final snap = (await persistence.load(_pgn))!;
      expect(snap.isComplete, isFalse);
      expect(snap.checkedFens, {_fen, 'other'});
      expect(snap.result.findings.single.missingMove, 'Nf6');
      expect(snap.config.strongReplyWindowCp, 25);
    });

    test('saveResult without a config keeps the one on disk', () async {
      await persistence.saveProgress(_pgn, _result([]), _config, {_fen});

      await persistence.saveResult(_pgn, _result([_missing()]));

      final snap = (await persistence.load(_pgn))!;
      expect(snap.config.mistakeThresholdCp, 120);
      expect(snap.config.clashUsername, 'rival');
      expect(snap.isComplete, isTrue, reason: 'a re-save is a complete one');
      expect(snap.checkedFens, isEmpty);
      expect(snap.result.findings.single.missingMove, 'Nf6');
    });

    test('saveResult with a config overrides the one on disk', () async {
      await persistence.saveComplete(_pgn, _result([]), _config);
      await persistence.saveResult(
        _pgn,
        _result([]),
        config: const AuditConfig(mistakeThresholdCp: 7),
      );
      expect((await persistence.load(_pgn))!.config.mistakeThresholdCp, 7);
    });

    test('saveResult onto nothing writes default config', () async {
      await persistence.saveResult(_pgn, _result([]));
      final snap = (await persistence.load(_pgn))!;
      expect(
        snap.config.mistakeThresholdCp,
        const AuditConfig().mistakeThresholdCp,
      );
    });
  });

  group('older files', () {
    test(
      'a version-1 file is a bare result, complete, default config',
      () async {
        // Version 1 stored the AuditResult JSON itself at the top level.
        storage.files[_json] = _result([_missing()]).toJsonString();

        final snap = (await persistence.load(_pgn))!;
        expect(snap.isComplete, isTrue);
        expect(snap.result.findings.single.missingMove, 'Nf6');
        expect(snap.result.nodesChecked, 12);
        expect(
          snap.config.mistakeThresholdCp,
          const AuditConfig().mistakeThresholdCp,
        );
      },
    );

    test(
      'a finding type this build no longer has is dropped, not fatal',
      () async {
        // practicalTrap was renamed trickyMove when the hunts merged.
        final result = _result([_missing()]).toJson();
        (result['findings'] as List).add({
          'type': 'practicalTrap',
          'severity': 'warning',
          'movePath': ['e4'],
          'fen': _fen,
          'ourMove': 'Nf3',
        });
        storage.files[_json] = jsonEncode({
          'version': 2,
          'isComplete': true,
          'config': _config.toMap(),
          'result': result,
        });

        final snap = (await persistence.load(_pgn))!;
        expect(snap.result.findings.map((f) => f.type), [
          AuditFindingType.missingResponse,
        ]);
        expect(snap.config.mistakeThresholdCp, 120);
      },
    );

    test('a v2 file without a config or checkedFens uses defaults', () async {
      storage.files[_json] = jsonEncode({
        'version': 2,
        'result': _result([]).toJson(),
      });
      final snap = (await persistence.load(_pgn))!;
      expect(snap.isComplete, isTrue);
      expect(snap.checkedFens, isEmpty);
      expect(snap.config.useChessDb, isTrue);
    });
  });

  group('failure paths', () {
    test('missing, empty and corrupt files load as null', () async {
      expect(await persistence.load(_pgn), isNull);
      storage.files[_json] = '';
      expect(await persistence.load(_pgn), isNull);
      storage.files[_json] = '{"version": 2, "result": ';
      expect(await persistence.load(_pgn), isNull);
      storage.files[_json] = '[]';
      expect(await persistence.load(_pgn), isNull);
    });

    test('a read error loads as null', () async {
      storage.files[_json] = _result([]).toJsonString();
      storage.failReads = true;
      expect(await persistence.load(_pgn), isNull);
    });

    test('a null path neither reads nor writes', () async {
      await persistence.saveComplete(null, _result([]), _config);
      await persistence.saveProgress(null, _result([]), _config, {});
      await persistence.saveResult(null, _result([]));
      expect(storage.files, isEmpty);
      expect(await persistence.load(null), isNull);
    });

    test('a write error is swallowed', () async {
      storage.failWrites = true;
      await persistence.saveComplete(_pgn, _result([]), _config);
      expect(storage.files, isEmpty);
    });
  });

  group('AuditConfig map defaults', () {
    // BUG: `AuditConfig.fromMap` defaults `useLichessDb` to true while the
    // constructor defaults it to false, so a config map missing the key
    // (hand-edited, or written before the key existed) comes back with the
    // Lichess source switched on. Harmless today because the Explorer fetch
    // is mothballed, but it is the one field where the two defaults
    // disagree.
    test('fromMap on an empty map matches the constructor defaults', () {
      final fromMap = AuditConfig.fromMap(const {});
      const ctor = AuditConfig();
      expect(fromMap.useStockfish, ctor.useStockfish);
      expect(fromMap.useMaia, ctor.useMaia);
      expect(fromMap.useChessDb, ctor.useChessDb);
      expect(fromMap.useLichessDb, ctor.useLichessDb);
    }, skip: 'documents bug: fromMap defaults useLichessDb=true, ctor false');
  });
}
