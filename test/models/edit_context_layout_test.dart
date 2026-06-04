import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/edit_context_layout.dart';
import 'package:chess_auto_prep/widgets/layout/repertoire_mode.dart';

void main() {
  test('defaultLayout places lines in second column', () {
    final layout = EditContextLayout.defaultLayout;
    expect(layout.columns.length, 2);
    expect(layout.columns.first.views, contains(EditContextView.browse));
    expect(layout.columns.last.views, contains(EditContextView.lines));
  });

  test('syncVisible adds newly enabled view to layout', () {
    final layout = EditContextLayout(
      columns: [
        EditContextColumnLayout(views: [EditContextView.browse]),
      ],
    );
    final synced = layout.syncVisible({
      EditContextView.browse,
      EditContextView.engine,
    });
    expect(synced.allPlacedViews, {
      EditContextView.browse,
      EditContextView.engine,
    });
  });

  test('round-trip JSON preserves columns', () {
    final original = EditContextLayout.defaultLayout;
    final restored = EditContextLayout.fromJson(original.toJson());
    expect(restored.columns.length, original.columns.length);
    expect(restored.columns.first.views, original.columns.first.views);
  });
}
