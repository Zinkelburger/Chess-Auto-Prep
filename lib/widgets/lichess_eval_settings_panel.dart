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
import 'package:provider/provider.dart';

import '../features/settings/widgets/settings_section_status.dart';

import '../features/settings/controllers/eval_database_settings.dart';
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
  late final EvalDatabaseSettings _settings;
  late final LichessEvalController _controller;

  @override
  void initState() {
    super.initState();
    _settings = context.read<EvalDatabaseSettings>();
    _controller = context.read<LichessEvalController>();
    unawaited(_settings.ensureLoaded().catchError((Object _) {}));
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
    final status = SettingsSectionStatus(
      owner: _settings,
      policy: 'Saved preferences apply to new builds and lookups.',
    );
    if (_settings.state.committed == null) return status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        status,
        AppSwitch(
          label: 'Use saved Lichess evaluations',
          value: _settings.editing.enableLichessEvals,
          onChanged: (v) {
            if (!mounted) return;
            unawaited(
              _settings.setEnableLichessEvals(v).catchError((Object _) {}),
            );
          },
          enabled: _controller.isReady && !_settings.state.busy,
          tooltip:
              'Consult the local Lichess store after the ChessDB dump and '
              'before the engine.',
          disabledReason: 'No built store on this machine yet.',
        ),
        if (_settings.editing.lichessEvalsPath.isNotEmpty) ...[
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
            _settings.editing.lichessEvalsPath,
            style: AppTextStyles.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: 'Show in file manager',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          onPressed: () =>
              unawaited(openInFileManager(_settings.editing.lichessEvalsPath)),
          icon: const Icon(Icons.open_in_new),
        ),
      ],
    );
  }
}
