import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/core/app_state.dart';

void main() {
  test('interactive-engine modes cover the IndexedStack engine panes', () {
    expect(AppMode.tactics.usesInteractiveEngine, isTrue);
    expect(AppMode.positionAnalysis.usesInteractiveEngine, isTrue);
    expect(AppMode.repertoire.usesInteractiveEngine, isTrue);
    expect(AppMode.pgnViewer.usesInteractiveEngine, isTrue);
    expect(AppMode.study.usesInteractiveEngine, isTrue);
    expect(AppMode.repertoireTrainer.usesInteractiveEngine, isFalse);
    expect(AppMode.tournament.usesInteractiveEngine, isFalse);
  });
}
