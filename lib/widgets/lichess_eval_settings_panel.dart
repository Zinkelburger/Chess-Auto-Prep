/// Downloading and managing the Lichess cloud evaluations.
///
/// Kept apart from [EvalDatabaseSettingsPanel] on purpose: that panel is
/// gated on the cdbdirect native reader, which exists only on Linux, whereas
/// this store is plain Dart and works everywhere.  The two are alternatives —
/// ChessDB is far broader, Lichess is far smaller and needs no native code —
/// so both can be on at once and the chain asks ChessDB first.
///
/// The status-and-download half lives in [LichessEvalCard], which both the
/// Databases page and the repertoire builder's eval-sources pane mount; what
/// stays here is the settings, shown in the card's disclosure.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/eval_database_settings.dart';
import '../services/eval/lichess_eval_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/open_in_file_manager.dart';
import 'labeled_toggle.dart';

class LichessEvalSettingsPanel extends StatefulWidget {
  const LichessEvalSettingsPanel({super.key});

  @override
  State<LichessEvalSettingsPanel> createState() =>
      _LichessEvalSettingsPanelState();
}

class _LichessEvalSettingsPanelState extends State<LichessEvalSettingsPanel> {
  final EvalDatabaseSettings _settings = EvalDatabaseSettings.instance;
  final LichessEvalController _controller = LichessEvalController.instance;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSwitch(
          label: 'Look here before the engine',
          value: _settings.enableLichessEvals,
          onChanged: (v) => unawaited(_settings.setEnableLichessEvals(v)),
          enabled: _controller.isReady,
          tooltip:
              'Consult the local Lichess store after the ChessDB dump and '
              'before the engine.',
          disabledReason: 'No built store on this machine yet.',
        ),
        if (_settings.lichessEvalsPath.isNotEmpty) ...[
          const SizedBox(height: 8),
          _pathLine(),
        ],
      ],
    );
  }

  Widget _pathLine() {
    return Row(
      children: [
        const Icon(Icons.folder_outlined, size: 14, color: AppColors.outline),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _settings.lichessEvalsPath,
            style: AppTextStyles.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: 'Show in file manager',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          onPressed: () =>
              unawaited(openInFileManager(_settings.lichessEvalsPath)),
          icon: const Icon(Icons.open_in_new),
        ),
      ],
    );
  }
}
