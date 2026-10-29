import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/line_preview.dart';

void main() {
  test('a rest shows once the pointer has stayed; a newer one replaces it', () {
    fakeAsync((async) {
      final preview = HoverPreview<String>();
      preview.rest(() => 'e4');
      async.elapse(previewDelay ~/ 2);
      preview.rest(() => 'd4');
      async.elapse(previewDelay ~/ 2);
      expect(preview.value, isNull);
      async.elapse(previewDelay);
      expect(preview.value, 'd4');
      preview.dispose();
    });
  });

  test('leaving clears the board and a rest still being timed', () {
    fakeAsync((async) {
      final preview = HoverPreview<String>();
      preview.rest(() => 'e4');
      async.elapse(previewDelay);
      preview.rest(() => 'd4');
      preview.leave();
      async.elapse(previewDelay * 2);
      expect(preview.value, isNull);
      preview.dispose();
    });
  });

  test('a rest answering nothing leaves the board as it was', () {
    fakeAsync((async) {
      final preview = HoverPreview<String>();
      preview.rest(() => 'e4');
      async.elapse(previewDelay);
      preview.rest(() => null);
      async.elapse(previewDelay);
      expect(preview.value, 'e4');
      preview.dispose();
    });
  });

  test('disposing drops a rest still being timed', () {
    fakeAsync((async) {
      final preview = HoverPreview<String>();
      var asked = false;
      preview.rest(() {
        asked = true;
        return 'e4';
      });
      preview.dispose();
      async.elapse(previewDelay * 2);
      expect(asked, isFalse);
    });
  });
}
