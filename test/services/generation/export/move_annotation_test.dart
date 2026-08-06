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
      opponentEase: 0.42,
      myEase: 0.81,
      isOnlyMove: true,
      lastPlayedYear: 2024,
    );

    test('none emits nothing', () {
      expect(rich.toPgnComment(MoveAnnotationDetail.none), isNull);
    });

    test('likelihood emits only the reply probability', () {
      final comment = rich.toPgnComment(MoveAnnotationDetail.likelihood)!;

      expect(comment, '[%humanFrequency 0.312]');
    });

    test('full emits every metric that is present', () {
      final comment = rich.toPgnComment(MoveAnnotationDetail.full)!;

      expect(comment, contains('[%humanFrequency 0.312]'));
      expect(comment, contains('[%eval +0.31]'));
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
