import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
import 'package:chess_auto_prep/services/generation/export/move_annotator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MoveAnnotation.toPgnComment', () {
    const rich = MoveAnnotation(
      likelihood: 0.312,
      likelihoodSource: MoveLikelihoodSource.gameDatabase,
      gameCount: 1204,
      practicalScore: 0.542,
      evalCp: 31,
      expectimaxValue: 0.62,
      opponentEase: 0.42,
      myEase: 0.81,
      isOnlyMove: true,
      lastPlayedYear: 2024,
    );

    test('none emits nothing', () {
      expect(rich.toPgnComment(MoveAnnotationDetail.none), isNull);
    });

    test('likelihood emits the reply probability and any prose', () {
      final comment = rich.toPgnComment(MoveAnnotationDetail.likelihood)!;

      expect(comment, 'Only move. [%humanFrequency 0.312]');
      expect(
        const MoveAnnotation(
          likelihood: 0.312,
          likelihoodSource: MoveLikelihoodSource.gameDatabase,
        ).toPgnComment(MoveAnnotationDetail.likelihood),
        '[%humanFrequency 0.312]',
      );
    });

    test('full emits every metric that is present', () {
      final comment = rich.toPgnComment(MoveAnnotationDetail.full)!;

      expect(comment, contains('[%humanFrequency 0.312]'));
      expect(comment, contains('[%eval +0.31]'));
      // V = 0.62 → the same pawn scale as [%eval], so a reader can compare.
      expect(comment, contains('[%expectimax +'));
      expect(comment, contains('[%onlyMove]'));
      expect(comment, contains('[%myEase 0.81]'));
      expect(comment, contains('[%ease 0.42]'));
      expect(comment, contains('[%score 54.2%]'));
      expect(comment, contains('[%games 1204]'));
      expect(comment, contains('[%lastPlayed 2024]'));
    });

    test('omits absent fields rather than inventing neutral values', () {
      const sparse = MoveAnnotation(evalCp: -105);

      expect(sparse.toPgnComment(MoveAnnotationDetail.full), '[%eval -1.05]');
    });

    test('an empty annotation emits nothing at any detail level', () {
      for (final detail in MoveAnnotationDetail.values) {
        expect(MoveAnnotation.none.toPgnComment(detail), isNull);
      }
    });

    test('names the source of the likelihood', () {
      String? tagFor(MoveLikelihoodSource source) => MoveAnnotation(
        likelihood: 0.5,
        likelihoodSource: source,
      ).toPgnComment(MoveAnnotationDetail.likelihood);

      expect(tagFor(MoveLikelihoodSource.maia), '[%maiaProbability 0.500]');
      expect(
        tagFor(MoveLikelihoodSource.gameDatabase),
        '[%humanFrequency 0.500]',
      );
      expect(tagFor(MoveLikelihoodSource.engine), '[%engineReply 0.500]');
    });

    test('a single metric is enough to be worth emitting', () {
      // isEmpty decides whether the move gets a comment at all, so every
      // field it consults has to keep a lone annotation alive.
      const singles = <String, MoveAnnotation>{
        '[%eval +0.31]': MoveAnnotation(evalCp: 31),
        '[%myEase 0.81]': MoveAnnotation(myEase: 0.81),
        '[%ease 0.42]': MoveAnnotation(opponentEase: 0.42),
        '[%score 54.2%]': MoveAnnotation(practicalScore: 0.542),
        '[%lastPlayed 2024]': MoveAnnotation(lastPlayedYear: 2024),
      };

      singles.forEach((token, annotation) {
        expect(annotation.toPgnComment(MoveAnnotationDetail.full), token);
      });
    });

    test('a half-specified likelihood is dropped, not half-rendered', () {
      // A probability with no source has no honest tag to write, and a
      // source with no probability has no number: both are silently skipped
      // rather than emitted with a hole in them.
      expect(
        const MoveAnnotation(
          likelihood: 0.3,
        ).toPgnComment(MoveAnnotationDetail.full),
        isNull,
      );
      expect(
        const MoveAnnotation(
          likelihoodSource: MoveLikelihoodSource.maia,
          evalCp: 10,
        ).toPgnComment(MoveAnnotationDetail.full),
        '[%eval +0.10]',
      );
    });

    test('counters at zero are omitted rather than written as zero', () {
      expect(
        const MoveAnnotation(
          gameCount: 0,
          lastPlayedYear: 0,
          evalCp: 20,
        ).toPgnComment(MoveAnnotationDetail.full),
        '[%eval +0.20]',
      );
      expect(
        const MoveAnnotation(
          gameCount: 1,
          evalCp: 20,
        ).toPgnComment(MoveAnnotationDetail.full),
        '[%eval +0.20] [%games 1]',
      );
    });

    test('formats evaluations as signed pawns', () {
      String evalOf(int cp) =>
          MoveAnnotation(evalCp: cp).toPgnComment(MoveAnnotationDetail.full)!;

      expect(evalOf(0), '[%eval 0.00]');
      expect(evalOf(5), '[%eval +0.05]');
      expect(evalOf(-250), '[%eval -2.50]');
    });
  });

  group('MoveAnnotation.explanation', () {
    test('quotes the lead of an only-move when it is known', () {
      expect(
        const MoveAnnotation(isOnlyMove: true, onlyMoveLeadCp: 62).explanation,
        'Only move: the next best gives up 0.62.',
      );
      expect(const MoveAnnotation(isOnlyMove: true).glyph, '!');
    });

    test('warns about a hard-to-find move and names the natural one', () {
      expect(
        const MoveAnnotation(
          humanFrequency: 0.04,
          naturalAlternativeSan: 'Nf3',
          naturalAlternativeLossCp: 35,
        ).explanation,
        'Hard to find: only 4% of players see it; the natural Nf3 costs 0.35.',
      );
      expect(
        const MoveAnnotation(humanFrequency: 0.12).explanation,
        'Hard to find: only 12% of players see it.',
      );
      expect(
        const MoveAnnotation(
          humanFrequency: 0.004,
          naturalAlternativeSan: 'Bg2',
          naturalAlternativeLossCp: 4,
        ).explanation,
        'Hard to find: under 1% of players see it; the natural Bg2 is nearly '
        'as good.',
      );
      expect(const MoveAnnotation(humanFrequency: 0.5).explanation, isEmpty);
    });

    test('grades an opponent mistake and names the better move', () {
      const inaccuracy = MoveAnnotation(mistakeCp: 90, betterMoveSan: 'Bd7');
      const blunder = MoveAnnotation(mistakeCp: 297);

      expect(inaccuracy.explanation, 'Inaccuracy: gives up 0.90 against Bd7.');
      expect(inaccuracy.glyph, '?!');
      expect(blunder.explanation, 'Blunder: gives up 2.97.');
      expect(blunder.glyph, '?');
      expect(const MoveAnnotation(mistakeCp: 40).glyph, isNull);
    });

    // The two grading thresholds are user-visible words on a move: pin the
    // side of the line each loss falls on, not the numbers themselves.
    test('a loss of exactly a pawn and a half is already a blunder', () {
      const atBoundary = MoveAnnotation(mistakeCp: 150);
      const justUnder = MoveAnnotation(mistakeCp: 149);

      expect(atBoundary.explanation, 'Blunder: gives up 1.50.');
      expect(atBoundary.glyph, '?');
      expect(justUnder.explanation, 'Inaccuracy: gives up 1.49.');
      expect(justUnder.glyph, '?!');
    });

    test('a loss below the mistake floor is not written up at all', () {
      const atFloor = MoveAnnotation(mistakeCp: 80);
      const justUnder = MoveAnnotation(mistakeCp: 79);

      expect(atFloor.explanation, 'Inaccuracy: gives up 0.80.');
      expect(atFloor.glyph, '?!');
      expect(justUnder.explanation, isEmpty);
      expect(justUnder.glyph, isNull);
    });

    test('marks where master practice ends', () {
      expect(
        const MoveAnnotation(gameCount: 9, lastBookMove: true).explanation,
        'Last move seen in master games (9 games); from here the line is '
        'engine and Maia.',
      );
      expect(
        const MoveAnnotation(gameCount: 9, lastBookMove: true).isEmpty,
        isFalse,
      );
    });
  });

  group('notes', () {
    const base = MoveAnnotation(evalCp: 31);
    const transposition = 'Transposes to 1. d4 Nf6.';

    test('prose reaches the file even with the metrics switched off', () {
      const noted = MoveAnnotation(evalCp: 31, note: 'Improves on Kramnik.');

      expect(
        noted.toPgnComment(MoveAnnotationDetail.likelihood),
        'Improves on Kramnik.',
      );
      expect(
        noted.toPgnComment(MoveAnnotationDetail.full),
        'Improves on Kramnik. [%eval +0.31]',
      );
      // An empty note is not prose; it must not open the comment with a space.
      expect(
        const MoveAnnotation(
          evalCp: 31,
          note: '',
        ).toPgnComment(MoveAnnotationDetail.full),
        '[%eval +0.31]',
      );
    });

    test('a second note follows the first instead of replacing it', () {
      // The extractor's transposition note and the composer's improvement
      // note land on the same move; neither may swallow the other.
      expect(
        base.withNote('First.').withNote('Second.').note,
        'First. Second.',
      );
      expect(
        base.withNote('Prose.').withTransposition([
          'd4',
          'Nf6',
        ], transposition).note,
        'Prose. $transposition',
      );
      expect(
        base.withTransposition(['d4', 'Nf6'], transposition).note,
        transposition,
      );
    });

    test('withdrawing a transposition restores the prose that preceded it', () {
      final marked = base.withNote('Prose.').withTransposition([
        'd4',
        'Nf6',
      ], transposition);
      expect(
        marked.toPgnComment(MoveAnnotationDetail.full),
        'Prose. $transposition [%transposes d4 Nf6] [%eval +0.31]',
      );

      final withdrawn = marked.withoutTransposition(transposition);
      expect(withdrawn.note, 'Prose.');
      expect(withdrawn.transposesTo, isNull);
      expect(
        withdrawn.toPgnComment(MoveAnnotationDetail.full),
        'Prose. [%eval +0.31]',
      );
    });

    test('withdrawing the only note leaves no empty prose behind', () {
      final withdrawn = base
          .withTransposition(['d4', 'Nf6'], transposition)
          .withoutTransposition(transposition);

      expect(withdrawn.note, isNull);
      expect(
        withdrawn.toPgnComment(MoveAnnotationDetail.full),
        '[%eval +0.31]',
      );
    });

    test('prose we did not append is left alone', () {
      final other = base.withNote('Someone else wrote this.');

      expect(
        other.withoutTransposition(transposition).note,
        'Someone else wrote this.',
      );
    });
  });

  group('MoveAnnotationDetail', () {
    test('parses its own names and defaults on anything else', () {
      expect(MoveAnnotationDetail.parse('full'), MoveAnnotationDetail.full);
      expect(MoveAnnotationDetail.parse('none'), MoveAnnotationDetail.none);
      expect(
        MoveAnnotationDetail.parse('nonsense'),
        MoveAnnotationDetail.likelihood,
      );
      expect(MoveAnnotationDetail.parse(null), MoveAnnotationDetail.likelihood);
    });

    test('restores the setting from the boolean it replaced', () {
      expect(
        MoveAnnotationDetail.fromLegacyFlags(annotate: true),
        MoveAnnotationDetail.likelihood,
      );
      expect(
        MoveAnnotationDetail.fromLegacyFlags(annotate: false),
        MoveAnnotationDetail.none,
      );
    });
  });

  group('naming the source honestly', () {
    // The export used to assert Maia and the engine wrote the continuation
    // whatever had actually produced it. In a ChessDB book neither ever
    // runs, so both claims were plain falsehoods in the file.
    test('the theory boundary names what really continues the line', () {
      const ann = MoveAnnotation(gameCount: 8355);
      expect(
        ann
            .withLastBookMove(PostBookContinuation.engineAndMaia)
            .toPgnComment(MoveAnnotationDetail.full),
        contains('from here the line is engine and Maia'),
      );
      expect(
        ann
            .withLastBookMove(PostBookContinuation.chessDb)
            .toPgnComment(MoveAnnotationDetail.full),
        contains('from here the line is ChessDB'),
      );
    });

    test('a position-database move is not labelled as Maia policy', () {
      const ann = MoveAnnotation(
        likelihood: 1.0,
        likelihoodSource: MoveLikelihoodSource.positionDatabase,
      );
      final out = ann.toPgnComment(MoveAnnotationDetail.full)!;
      expect(out, contains('chessDbMove'));
      expect(out, isNot(contains('maiaProbability')));
    });
  });

  group('theory boundary threshold', () {
    const annotator = MoveAnnotator(
      playAsWhite: true,
      maxEvalLossCp: 50,
      bookMinGames: 3,
    );

    List<MoveAnnotation> withCounts(List<int?> counts) => [
      for (final n in counts) MoveAnnotation(gameCount: n),
    ];

    test(
      'marks the last move still in practice, not the last with any game',
      () {
        // 2 games is a curiosity; the line left practice after the 40-game move.
        final marked = annotator.markTheoryBoundary(
          withCounts([500, 120, 40, 2, null, null]),
        );
        expect(marked[2].lastBookMove, isTrue);
        expect(marked[3].lastBookMove, isFalse);
      },
    );

    test('a line still in practice at its leaf is left unmarked', () {
      final marked = annotator.markTheoryBoundary(withCounts([500, 120, 40]));
      expect(marked.every((a) => !a.lastBookMove), isTrue);
    });

    test('a line that was never in practice is left alone', () {
      final marked = annotator.markTheoryBoundary(withCounts([null, 1, null]));
      expect(marked.every((a) => !a.lastBookMove), isTrue);
    });
  });
}
