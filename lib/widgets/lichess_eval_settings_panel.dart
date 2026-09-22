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

import '../features/settings/controllers/eval_database_settings.dart';
import '../services/eval/lichess_eval_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/open_in_file_manager.dart';
import 'labeled_toggle.dart';

class LichessEvalSettingsPanel extends StatelessWidget {
  const LichessEvalSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<EvalDatabaseSettings>();
    final controller = context.watch<LichessEvalController>();
    if (settings.state.committed == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSwitch(
          label: 'Use saved Lichess evaluations',
          value: settings.editing.enableLichessEvals,
          onChanged: (v) {
            if (!context.mounted) return;
            unawaited(
              settings.setEnableLichessEvals(v).catchError((Object _) {}),
            );
          },
          enabled:
              controller.isReady && !settings.state.busy && !controller.isBusy,
          tooltip:
              'Consult the local Lichess store after the ChessDB dump and '
              'before the engine.',
          disabledReason: 'No built store on this machine yet.',
        ),
        if (settings.editing.lichessEvalsPath.isNotEmpty) ...[
          const SizedBox(height: 8),
          _pathLine(context, settings),
        ],
      ],
    );
  }

  Widget _pathLine(BuildContext context, EvalDatabaseSettings settings) {
    return Row(
      children: [
        const Icon(Icons.folder_outlined, size: 14, color: AppColors.outline),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            settings.editing.lichessEvalsPath,
            style: AppTextStyles.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: 'Show in file manager',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          onPressed: () =>
              unawaited(openInFileManager(settings.editing.lichessEvalsPath)),
          icon: const Icon(Icons.open_in_new),
        ),
      ],
    );
  }
}
