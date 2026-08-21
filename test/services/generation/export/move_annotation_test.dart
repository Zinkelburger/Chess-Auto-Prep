import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
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
}
