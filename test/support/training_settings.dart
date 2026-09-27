import 'dart:async';

import 'package:chess_auto_prep/features/training/models/training_configuration.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/features/settings/repositories/settings_section_storage.dart';
import 'package:chess_auto_prep/features/settings/models/section_configuration.dart';

class MemoryTrainingSettings
    implements SettingsSectionStorage<TrainingConfiguration> {
  MemoryTrainingSettings([TrainingSettings? initial])
    : value = TrainingConfiguration(initial ?? TrainingSettings());
  TrainingConfiguration value;
  Completer<TrainingConfiguration>? readGate;
  Completer<void>? writeGate;
  bool failWrites = false;
  bool failReads = false;
  int reads = 0;
  final writes = <SettingsPatch<TrainingConfiguration>>[];

  @override
  Future<TrainingConfiguration> read() async {
    reads++;
    if (failReads) throw StateError('Preferences cannot be read');
    final gate = readGate;
    readGate = null;
    return gate == null ? value : await gate.future;
  }

  @override
  Future<void> write(SettingsPatch<TrainingConfiguration> edit) async {
    writes.add(edit);
    await writeGate?.future;
    if (failWrites) throw StateError('Preferences unavailable');
    value = edit.apply(value);
  }
}

Map<String, Object?> trainingEdit(
  TrainingConfiguration from,
  void Function(TrainingSettings) change,
) {
  final draft = from.toSettings();
  change(draft);
  return TrainingConfiguration(draft).changesFrom(from);
}
