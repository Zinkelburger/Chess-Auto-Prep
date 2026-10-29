import 'dart:async';

import 'package:flutter/material.dart';

import '../../storage/settings.dart';
import '../../storage/settings_store.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';

/// What each engine setting is called, said the same way behind the engine
/// pane's gear and in Settings ▸ Engine.
abstract final class EngineSettingCopy {
  static const lines = 'Lines shown';
  static const cores = 'CPU cores';
  static const memory = 'Memory';
  static const engine = 'Analysis engine';

  /// The bundled engine, by the name the analysis-engine choice gives it;
  /// the release `tools/assets.lock.json` pins.
  static const builtIn = 'Stockfish 19 (built in)';

  /// What the cores box says after its number: how many there are.
  static String coresOf(int available) => 'of $available';

  /// The table size steps by this much, typed values being kept as typed.
  static const memoryStep = 64;
  static const minMemoryMb = 16;
}

/// How many rows the engine's settings take in place of its lines, each as
/// tall as a line, so opening them over the default lines moves nothing.
const engineSettingRows = 3;

/// The engine's own settings, shown in the engine pane where its lines
/// are: how many lines, how many cores, how much memory. One typeable
/// stepper a row, written to the same settings Settings ▸ Engine shows; a
/// change to cores or memory starts the engine again with them.
class EngineSettingsView extends StatelessWidget {
  const EngineSettingsView({
    super.key,
    required this.settings,
    required this.coresAvailable,
  });

  final SettingsStore settings;

  /// The cores this computer has: the most the engine may be given.
  final int coresAvailable;

  void _change(Settings Function(Settings now) edit) =>
      unawaited(settings.update(edit(settings.value)));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final s = settings.value;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _row(
                EngineSettingCopy.lines,
                value: s.engineLines,
                min: 1,
                max: Settings.maxLines,
                onChanged: (n) =>
                    _change((now) => now.copyWith(engineLines: n)),
              ),
              _row(
                EngineSettingCopy.cores,
                value: s.coresOn(coresAvailable),
                min: 1,
                max: coresAvailable,
                unit: EngineSettingCopy.coresOf(coresAvailable),
                onChanged: (n) =>
                    _change((now) => now.copyWith(engineCores: n)),
              ),
              _row(
                EngineSettingCopy.memory,
                value: s.engineMemoryMb,
                min: EngineSettingCopy.minMemoryMb,
                max: Settings.maxMemoryMb,
                step: EngineSettingCopy.memoryStep,
                unit: 'MB',
                onChanged: (n) =>
                    _change((now) => now.copyWith(engineMemoryMb: n)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(
    String label, {
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
    int step = 1,
    String? unit,
  }) => SizedBox(
    height: engineRowHeight,
    child: Row(
      children: [
        Expanded(
          child: Builder(
            builder: (context) => Text(
              label,
              style: Theme.of(context).textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: Space.s),
        Semantics(
          label: label,
          child: NumberField(
            label: label,
            value: value,
            min: min,
            max: max,
            step: step,
            unit: unit,
            onChanged: onChanged,
          ),
        ),
      ],
    ),
  );
}
