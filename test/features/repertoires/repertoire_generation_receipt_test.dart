import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/features/generation/controllers/generation_publication_controller.dart';
import 'package:chess_auto_prep/features/generation/models/generation_publication.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_draft_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/repertoire_dependencies.dart';

const original = '// Color: White\n\n[Event "Original"]\n\n1. e4 e5 *\n';
const generated = '[Event "Generated"]\n\n1. d4 d5 *\n';
const later = '[Event "Later"]\n\n1. c4 e5 *\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File file;
  late NativePgnDocumentStore documents;
  late GenerationPublicationController publication;
  late BuilderWorkspaceController builder;
  late GatedRepertoireDecoder decoder;
  RepertoireMetadata metadata(String path) => RepertoireMetadata(
    filePath: path,
    name: p.basename(path),
    lastModified: DateTime(2026),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('generation-receipt-');
    file = File(p.join(root.path, 'Main.pgn'));
    documents = NativePgnDocumentStore();
    await documents.create(file.path, original);
    final storage = IOStorageService(documentsRoot: root, supportRoot: root);
    publication = GenerationPublicationController(
      documents: documents,
      drafts: StorageGenerationDraftRepository(storage),
    );
    decoder = GatedRepertoireDecoder();
    builder = BuilderWorkspaceController(
      checkpoint: () async {},
      documents: DocumentRepertoireRepository(documents),
      decoder: decoder,
    );
    await builder.document.setRepertoire(metadata(file.path));
    builder.selectLine(builder.document.repertoireLines.single);
  });
  tearDown(() async {
    builder.dispose();
    await root.delete(recursive: true);
  });

  Future<GenerationPublished> generate([String game = generated]) async {
    final source = await publication.begin(file.path, {});
    final result = await publication.publish(source, games: [game]);
    expect(result, isA<GenerationPublished>());
    return result as GenerationPublished;
  }

  test(
    'receipt replaces baseline, parsed lines and metadata while preserving board',
    () async {
      final receive = builder.document.publishedDocumentReceiver;
      final saved = await generate();
      await receive(saved.snapshot);
      expect(builder.document.repertoirePgn, await file.readAsString());
      expect(builder.document.repertoireLines, hasLength(2));
      expect(builder.document.currentRepertoire!.gameCount, 2);
      expect(builder.board.currentMoveSequence, ['e4', 'e5']);
      expect(builder.document.selectedPgnLine?.headers['Event'], 'Original');
      // A subsequent whole-document edit must use the complete generated source.
      await builder.document.setRepertoireColor(false);
      expect(builder.document.loadError, isNull);
      expect(builder.document.repertoireLines, hasLength(2));
      expect(await file.readAsString(), contains('Generated'));
    },
  );

  test(
    'repeated runs use fresh receivers; replaying one receipt cannot append twice',
    () async {
      final firstReceiver = builder.document.publishedDocumentReceiver;
      final first = await generate();
      await firstReceiver(first.snapshot);
      await firstReceiver(first.snapshot);
      expect(builder.document.repertoireLines, hasLength(2));
      final secondReceiver = builder.document.publishedDocumentReceiver;
      final second = await generate(later);
      await secondReceiver(second.snapshot);
      expect(builder.document.repertoireLines, hasLength(3));
      expect(builder.document.repertoirePgn, await file.readAsString());
      await firstReceiver(first.snapshot);
      expect(builder.document.repertoireLines, hasLength(3));
    },
  );

  test(
    'a failed source publication never advances the Builder baseline',
    () async {
      final source = await publication.begin(file.path, {});
      await documents.save(source.snapshot!, '$original\n{external edit}');
      final result = await publication.publish(source, games: [generated]);
      expect(result, isA<GenerationPublicationRefused>());
      expect(builder.document.repertoirePgn, original);
      expect(builder.document.repertoireLines, hasLength(1));
    },
  );

  test(
    'failed refresh retains old state and reports that source was saved; retry adopts once',
    () async {
      final receive = builder.document.publishedDocumentReceiver;
      final saved = await generate();
      decoder.beforeBuild = () async => throw StateError('decode unavailable');
      await expectLater(receive(saved.snapshot), throwsStateError);
      expect(builder.document.repertoirePgn, original);
      expect(builder.document.repertoireLines, hasLength(1));
      expect(builder.board.currentMoveSequence, ['e4', 'e5']);
      expect(builder.document.isLoading, isFalse);
      expect(builder.document.loadError, contains('saved'));
      expect(await file.readAsString(), saved.snapshot.content);
      decoder.beforeBuild = null;
      await builder.document.publishedDocumentReceiver(saved.snapshot);
      expect(builder.document.repertoirePgn, saved.snapshot.content);
      expect(builder.document.repertoireLines, hasLength(2));
      expect(builder.document.loadError, isNull);
    },
  );

  test(
    'pending editor save after publication is drained before adopting the source',
    () async {
      final receive = builder.document.publishedDocumentReceiver;
      final saveLine = builder.document.selectedLineSaver!;
      final selected = builder.document.selectedPgnLine!;
      final saved = await generate();
      final changed = selected.fullPgn.replaceFirst('e4', 'e4 {my annotation}');
      unawaited(saveLine(changed));
      await receive(saved.snapshot);
      expect(builder.document.repertoirePgn, await file.readAsString());
      expect(builder.document.repertoirePgn, contains('my annotation'));
      expect(builder.document.repertoireLines, hasLength(2));
    },
  );

  test(
    'line save advances the full baseline before the next append and undo',
    () async {
      final save = builder.document.selectedLineSaver!;
      final changed = builder.document.selectedPgnLine!.fullPgn.replaceFirst(
        'e5',
        'e5 {saved annotation}',
      );
      expect(await save(changed), isTrue);
      expect(builder.document.repertoirePgn, await file.readAsString());
      await builder.writer.addMovesAtPosition(
        pathFromRoot: ['e4', 'e5'],
        sans: ['Nf3'],
      );
      expect(builder.document.repertoirePgn, await file.readAsString());
      expect(await builder.writer.undo(), isTrue);
      expect(builder.document.repertoirePgn, await file.readAsString());
      expect(builder.document.repertoirePgn, contains('saved annotation'));
    },
  );

  test(
    'line receipt adopts external other games and preserves board and selection',
    () async {
      final save = builder.document.selectedLineSaver!;
      await generate();
      expect(
        await save(
          builder.document.selectedPgnLine!.fullPgn.replaceFirst(
            'e5',
            'e5 {saved annotation}',
          ),
        ),
        isTrue,
      );
      expect(builder.document.repertoirePgn, await file.readAsString());
      expect(builder.document.repertoireLines, hasLength(2));
      expect(builder.document.currentRepertoire!.gameCount, 2);
      expect(builder.board.currentMoveSequence, ['e4', 'e5']);
      expect(
        builder.document.selectedPgnLine!.fullPgn,
        contains('saved annotation'),
      );
    },
  );

  test(
    'failed line refresh keeps session atomic and retained save can retry',
    () async {
      final save = builder.document.selectedLineSaver!;
      final before = builder.document.repertoireLines;
      final edited = builder.document.selectedPgnLine!.fullPgn.replaceFirst(
        'e5',
        'e5 {first annotation}',
      );
      decoder.beforeBuild = () async => throw StateError('decode unavailable');
      await expectLater(save(edited), throwsStateError);
      expect(builder.document.repertoirePgn, original);
      expect(builder.document.repertoireLines, same(before));
      expect(builder.document.loadError, contains('Line was saved'));
      expect(await file.readAsString(), contains('first annotation'));
      decoder.beforeBuild = null;
      expect(await save(edited.replaceFirst('first', 'second')), isTrue);
      expect(builder.document.repertoirePgn, await file.readAsString());
      expect(builder.document.loadError, isNull);
    },
  );

  test(
    'retained and newly captured line savers share committed baselines',
    () async {
      final retained = builder.document.selectedLineSaver!;
      final text = builder.document.selectedPgnLine!.fullPgn;
      expect(await retained(text.replaceFirst('e5', 'e5 {first}')), isTrue);
      final newer = builder.document.selectedLineSaver!;
      expect(await retained(text.replaceFirst('e5', 'e5 {second}')), isTrue);
      expect(await newer(text.replaceFirst('e5', 'e5 {third}')), isTrue);
      expect(builder.document.repertoirePgn, await file.readAsString());
      expect(builder.document.repertoirePgn, contains('{third}'));
    },
  );

  test(
    'a slower line refresh serializes the next append acknowledgement',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      decoder.beforeBuild = () async {
        decoder.beforeBuild = null;
        entered.complete();
        await release.future;
      };
      final save = builder.document.selectedLineSaver!(
        builder.document.selectedPgnLine!.fullPgn.replaceFirst(
          'e5',
          'e5 {annotation}',
        ),
      );
      await entered.future;
      final append = builder.writer.addMovesAtPosition(
        pathFromRoot: ['e4', 'e5'],
        sans: ['Nf3'],
      );
      expect(await file.readAsString(), isNot(contains('Nf3')));
      release.complete();
      expect(await save, isTrue);
      await append;
      expect(builder.document.repertoirePgn, await file.readAsString());
      expect(builder.document.repertoirePgn, contains('Nf3'));
      expect(builder.document.repertoirePgn, contains('annotation'));
    },
  );

  test(
    'retained structural line edits keep selection and the full baseline',
    () async {
      final save = builder.document.selectedLineSaver!;
      final before = builder.document.selectedPgnLine!.fullPgn;
      expect(await save(before.replaceFirst('e4 e5', 'd4 d5')), isTrue);
      expect(builder.document.selectedPgnLine!.moves, ['d4', 'd5']);
      expect(await save(before.replaceFirst('e4 e5', 'c4 e5')), isTrue);
      expect(builder.document.selectedPgnLine!.moves, ['c4', 'e5']);
      expect(builder.document.repertoirePgn, await file.readAsString());
    },
  );

  test('A to B to A makes the original receipt receiver stale', () async {
    final receive = builder.document.publishedDocumentReceiver;
    final other = p.join(root.path, 'Other.pgn');
    await documents.create(other, later);
    await builder.document.setRepertoire(metadata(other));
    await builder.document.setRepertoire(metadata(file.path));
    final saved = await generate();
    await receive(saved.snapshot);
    expect(builder.document.repertoirePgn, original);
    expect(builder.document.repertoireLines, hasLength(1));
    await builder.document.publishedDocumentReceiver(saved.snapshot);
    expect(builder.document.repertoireLines, hasLength(2));
  });

  test(
    'a receipt decoding during a chapter switch cannot land on the new chapter',
    () async {
      final receive = builder.document.publishedDocumentReceiver;
      final saved = await generate();
      final entered = Completer<void>();
      final release = Completer<void>();
      decoder.beforeBuild = () async {
        decoder.beforeBuild = null;
        entered.complete();
        await release.future;
      };
      final refresh = receive(saved.snapshot);
      await entered.future;
      final other = p.join(root.path, 'Other.pgn');
      await documents.create(other, later);
      await builder.document.setRepertoire(metadata(other));
      release.complete();
      await refresh;
      expect(builder.document.currentRepertoire!.filePath, other);
      expect(builder.document.repertoirePgn, later);
      expect(builder.document.repertoireLines, hasLength(1));
    },
  );
}
