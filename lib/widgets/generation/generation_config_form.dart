import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../constants/engine_defaults.dart';
import '../../models/eval_database_settings.dart';
import '../../services/eval/cdbdirect_eval_provider.dart';
import '../../services/generation/generation_config.dart';
import '../../services/generation/generation_presets.dart';
import '../../services/master_games/master_games_service.dart';
import '../../services/master_games/twic_client.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/app_messages.dart';
import '../labeled_toggle.dart';
import '../pgn_sources_controller.dart';
import '../pgn_sources_panel.dart';
import 'advanced_settings_dialog.dart';
import 'engine_resources_section.dart';
import 'eval_sources_controller.dart';
import 'eval_sources_section.dart';
import 'skeleton_plan_card.dart';
import 'skeleton_plan_controller.dart';

part 'generation_config_form_state_base.dart';
part 'generation_config_form_descriptions.dart';
part 'generation_config_form_fields.dart';
part 'generation_config_form_io.dart';
part 'generation_config_form_card.dart';
part 'generation_config_form_advanced.dart';

/// Settings form for repertoire tree generation.
///
/// Layer 1 (always visible) is a three-section card — Opponent, What to
/// build, Search (Fast/Pure plus four budgets) — plus saved presets and a
/// live plain-language summary. Every other knob lives in the Advanced
/// dialog; both layers edit the same controllers, so they cannot disagree.
///
/// The three sub-editors — eval sources, the skeleton plan, the PGN sources
/// panel — are views over controllers this state owns, so what the user typed
/// survives their widgets being collapsed or switched away from.
class GenerationConfigForm extends StatefulWidget {
  final TreeBuildConfig? initialConfig;
  final bool isGenerating;
  final bool playAsWhite;

  const GenerationConfigForm({
    super.key,
    this.initialConfig,
    required this.isGenerating,
    required this.playAsWhite,
  });

  @override
  State<GenerationConfigForm> createState() => GenerationConfigFormState();
}

class GenerationConfigFormState extends _GenerationConfigFormStateBase
    with
        _GenerationConfigDescriptions,
        _GenerationConfigFields,
        _GenerationConfigIo,
        _GenerationConfigCard,
        _GenerationConfigAdvanced {
  @override
  void initState() {
    super.initState();
    if (widget.initialConfig != null) {
      _applyInitialConfig(widget.initialConfig!);
    }
    unawaited(
      CdbDirectEvalProvider.probeAvailability().then((available) {
        if (!mounted) return;
        setState(() => _cdbDirectAvailable = available);
      }),
    );
    // The usage line reads today's spend even while the section is collapsed.
    unawaited(_evalSources.refreshApiUsage());
    unawaited(_reloadPresets());
  }

  @override
  void didUpdateWidget(covariant GenerationConfigForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialConfig != oldWidget.initialConfig &&
        widget.initialConfig != null) {
      _applyInitialConfig(widget.initialConfig!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Source (What to build) sits above the search fields it gates;
        // _opponentSection draws no leading rule so the top stays clean.
        _opponentSection(),
        _outputSection(),
        _searchSection(),
        const Divider(height: 24),
        _skeletonSection(),
        const Divider(height: 24),
        Row(
          children: [
            _presetsMenu(),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _openAdvancedDialog,
              icon: const Icon(Icons.tune, size: 16),
              label: const Text('Advanced…', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _summary(),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _showEvalSources = !_showEvalSources),
          child: Row(
            children: [
              Icon(
                _showEvalSources ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: AppColors.onSurfaceSoft,
              ),
              const SizedBox(width: 4),
              const Text(
                'Evaluation databases (optional)',
                style: TextStyle(fontSize: 13, color: AppColors.onSurfaceSoft),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: _cdbDirectAvailable
                    ? 'Optional eval lookup chain before Stockfish:\n'
                          'project cache → cdbdirect full dump → local SQLite '
                          '→ API → engine.\n'
                          'On HDD, enable read-ahead and batch lookups for '
                          'cdbdirect.'
                    : 'Optional eval lookup chain before Stockfish:\n'
                          'project cache → local SQLite → API → engine.',
                child: const Icon(
                  Icons.info_outline,
                  size: 16,
                  color: AppColors.onSurfaceMuted,
                ),
              ),
            ],
          ),
        ),
        if (_showEvalSources)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: EvalSourcesSection(
              controller: _evalSources,
              isGenerating: widget.isGenerating,
              cdbDirectAvailable: _cdbDirectAvailable,
            ),
          ),
      ],
    );
  }
}
