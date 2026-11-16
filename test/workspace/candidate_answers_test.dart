import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/workspace/search/search_opponents.dart';
import 'package:dartchess/dartchess.dart' show Chess, Position;
import 'package:flutter_test/flutter_test.dart';

/// A shortlist that answers from [answers] in turn; a null entry is no
/// ranking, and [throwsAtOnce] makes the first ask throw before it returns.
final class Answers implements CandidateSource {
  Answers(this.answers, {this.throwsAtOnce = false});

  final List<List<String>?> answers;
  final bool throwsAtOnce;
  var asked = 0;

  @override
  Future<List<String>?> candidates(Position position, int count) {
    asked++;
    if (throwsAtOnce && asked == 1) throw StateError('engine gone');
    return Future.value(answers[asked - 1]);
  }
}

void main() {
  const position = Chess.initial;

  test('a ranking is asked once per position and count', () async {
    final source = Answers([
      ['e2e4'],
    ]);
    final answers = CandidateAnswers(source);
    expect(await answers.candidates(position, 1), ['e2e4']);
    expect(await answers.candidates(position, 1), ['e2e4']);
    expect(source.asked, 1);
  });

  test('a ranking that failed is asked again, even one that threw at '
      'once', () async {
    final source = Answers([
      null,
      ['d2d4'],
    ], throwsAtOnce: true);
    final answers = CandidateAnswers(source);
    await expectLater(answers.candidates(position, 1), throwsStateError);
    expect(await answers.candidates(position, 1), ['d2d4']);
    expect(await answers.candidates(position, 1), ['d2d4']);
    expect(source.asked, 2);
  });

  test('no ranking is asked again', () async {
    final source = Answers([
      null,
      ['c2c4'],
    ]);
    final answers = CandidateAnswers(source);
    expect(await answers.candidates(position, 1), isNull);
    await pumpEventQueue();
    expect(await answers.candidates(position, 1), ['c2c4']);
  });
}
