import 'dart:async';

import 'package:chess_auto_prep/features/training/models/training_configuration.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/features/training/repositories/training_settings_repository.dart';

class MemoryTrainingSettings implements TrainingSettingsStorage {
  MemoryTrainingSettings([TrainingSettings? initial])
    : value = TrainingConfiguration(initial ?? TrainingSettings());
  TrainingConfiguration value;
  Completer<TrainingConfiguration>? readGate;
  Completer<void>? writeGate;
  bool failWrites = false;
  bool failReads = false;
  int reads = 0;
  final writes = <TrainingSettingsPatch>[];

  @override
  Future<TrainingConfiguration> read() async {
    reads++;
    if (failReads) throw StateError('Preferences cannot be read');
    final gate = readGate;
    readGate = null;
    return gate == null ? value : await gate.future;
  }

  @override
  Future<void> write(TrainingSettingsPatch edit) async {
    writes.add(edit);
    await writeGate?.future;
    if (failWrites) throw StateError('Preferences unavailable');
    value = edit.apply(value);
  }
}

TrainingSettingsPatch trainingEdit(
  TrainingConfiguration from,
  void Function(TrainingSettings) change,
) {
  final draft = from.toSettings();
  change(draft);
  return TrainingSettingsPatch.between(from, TrainingConfiguration(draft));
}
