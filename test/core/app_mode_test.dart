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
    // The tournament runs its own engines; the analysis pool would only
    // compete with them for cores.
    expect(AppMode.engineTournament.usesInteractiveEngine, isFalse);
    // Databases has no board: it reads file sizes.
    expect(AppMode.databases.usesInteractiveEngine, isFalse);
  });

  test('every mode has a label of its own', () {
    final labels = AppMode.values.map((m) => m.label).toList();
    expect(labels.toSet().length, labels.length);
    expect(AppMode.engineTournament.label, 'Engine tournament');
    expect(AppMode.databases.label, 'Databases');
  });
}
