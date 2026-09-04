import 'package:chess_auto_prep/utils/pgn_comment_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('comment editing keeps machine tokens', () {
    test('prose hides the tokens the app wrote', () {
      expect(
        commentProse('[%eval 0.31] [%clk 0:02:44.3] Solid, but slow.'),
        'Solid, but slow.',
      );
      expect(commentProse('[%eval 0.31]'), '');
      expect(commentProse('Just prose.'), 'Just prose.');
    });

    test('an edit puts every token back', () {
      const raw = '[%eval 0.31] [%pv Nf3,Bb4] Solid, but slow.';
      expect(
        mergeCommentProse(raw, 'Actually sharp.'),
        '[%eval 0.31] [%pv Nf3,Bb4] Actually sharp.',
      );
    });

    test('clearing the field keeps the analysis, not the prose', () {
      const raw = '[%eval -1.2] Blunder.';
      expect(mergeCommentProse(raw, '   '), '[%eval -1.2]');
    });

    test('a comment with no tokens round-trips as typed', () {
      expect(mergeCommentProse('Old note.', 'New note.'), 'New note.');
      expect(mergeCommentProse('', 'First note.'), 'First note.');
    });

    test('book double-spacing survives the round trip', () {
      const raw = '[%clk 0:01:00] First para.  Second para.';
      expect(commentProse(raw), 'First para.  Second para.');
      expect(
        mergeCommentProse(raw, 'First para.  Second para.'),
        '[%clk 0:01:00] First para.  Second para.',
      );
    });
  });
}
