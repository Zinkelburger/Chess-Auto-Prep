import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/engine/engine_lifecycle.dart';

/// Board toolbar button for engine on/off.
/// Shows state via icon color and optional spinner.
class EngineToggleButton extends StatelessWidget {
  const EngineToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final lifecycle = context.watch<EngineLifecycle>();
    final state = lifecycle.state;
    final isOn = state != EngineState.off;
    final isGenerating = state == EngineState.generating;
    final isAnalyzing = state == EngineState.analyzing;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: isAnalyzing
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                )
              : Icon(
                  Icons.bolt,
                  color: isGenerating
                      ? Colors.grey
                      : isOn
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
          tooltip: isGenerating
              ? 'Engine busy — repertoire generation in progress'
              : isOn
              ? 'Disable engine analysis'
              : 'Enable engine analysis',
          onPressed: isGenerating
              ? null
              : () {
                  if (isOn) {
                    lifecycle.toggleOff();
                  } else {
                    lifecycle.toggleOn();
                  }
                },
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
