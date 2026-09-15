import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/generation_session_controller.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/system_info.dart';
import '../../../widgets/common/number_stepper.dart';

/// Shared by the repertoire menu and the evaluation table's settings button.
class PositionGenerationSettings {
  const PositionGenerationSettings({
    required this.plies,
    required this.cores,
    required this.engineMoves,
    required this.maiaCoverage,
  });

  final int plies;
  final int cores;
  final int engineMoves;
  final int maiaCoverage;

  static const _prefix = 'position_generation.';

  static Future<PositionGenerationSettings> load(
    GenerationSessionController generation,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final config = generation.lastConfig;
    return PositionGenerationSettings(
      plies: (prefs.getInt('${_prefix}plies') ?? config?.maxPly ?? 6).clamp(
        1,
        60,
      ),
      cores:
          (prefs.getInt('${_prefix}cores') ??
                  config?.resolvedEngineThreads ??
                  1)
              .clamp(1, getLogicalCores()),
      engineMoves: (prefs.getInt('${_prefix}engineMoves') ?? 4).clamp(1, 20),
      maiaCoverage: (prefs.getInt('${_prefix}maiaCoverage') ?? 60).clamp(
        1,
        100,
      ),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}plies', plies);
    await prefs.setInt('${_prefix}cores', cores);
    await prefs.setInt('${_prefix}engineMoves', engineMoves);
    await prefs.setInt('${_prefix}maiaCoverage', maiaCoverage);
  }
}

Future<void> showPositionGenerationSettings(
  BuildContext context,
  GenerationSessionController generation,
) async {
  final settings = await PositionGenerationSettings.load(generation);
  if (!context.mounted) return;
  final result = await showDialog<PositionGenerationSettings>(
    context: context,
    builder: (_) => _GenerationSettingsDialog(settings: settings),
  );
  if (result != null) await result.save();
}

class _GenerationSettingsDialog extends StatefulWidget {
  const _GenerationSettingsDialog({required this.settings});
  final PositionGenerationSettings settings;

  @override
  State<_GenerationSettingsDialog> createState() =>
      _GenerationSettingsDialogState();
}

class _GenerationSettingsDialogState extends State<_GenerationSettingsDialog> {
  final _form = GlobalKey<FormState>();
  late int _plies = widget.settings.plies;
  late int _cores = widget.settings.cores;
  late int _engineMoves = widget.settings.engineMoves;
  late int _maiaCoverage = widget.settings.maiaCoverage;

  Widget _setting(String label, Widget control) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Expanded(child: Text(label, style: AppTextStyles.body)),
        control,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Generation settings'),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _setting(
                'Depth (half-moves)',
                NumberStepper(
                  key: const ValueKey('generate-depth'),
                  value: _plies,
                  min: 1,
                  max: 60,
                  onChanged: (value) {
                    if (mounted) setState(() => _plies = value);
                  },
                ),
              ),
              _setting(
                'CPU cores',
                NumberStepper(
                  key: const ValueKey('generate-cores'),
                  value: _cores,
                  min: 1,
                  max: getLogicalCores(),
                  onChanged: (value) {
                    if (mounted) setState(() => _cores = value);
                  },
                ),
              ),
              _setting(
                'Engine moves',
                NumberStepper(
                  key: const ValueKey('generate-engine-moves'),
                  value: _engineMoves,
                  min: 1,
                  max: 20,
                  onChanged: (value) {
                    if (mounted) setState(() => _engineMoves = value);
                  },
                ),
              ),
              _setting(
                'Maia coverage',
                NumberStepper(
                  key: const ValueKey('generate-maia-coverage'),
                  value: _maiaCoverage,
                  min: 1,
                  max: 100,
                  step: 5,
                  suffix: '%',
                  onChanged: (value) {
                    if (mounted) setState(() => _maiaCoverage = value);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          _form.currentState!.save();
          Navigator.pop(
            context,
            PositionGenerationSettings(
              plies: _plies,
              cores: _cores,
              engineMoves: _engineMoves,
              maiaCoverage: _maiaCoverage,
            ),
          );
        },
        child: const Text('Done'),
      ),
    ],
  );
}
