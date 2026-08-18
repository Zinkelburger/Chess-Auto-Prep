import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../features/games/services/games_window.dart';
import '../../models/tactics_position.dart';
import '../../models/tactics_session_settings.dart';
import '../../services/tactics/tactics_import_form.dart';
import '../../services/tactics/tactics_session_controller.dart';
import '../../theme/app_colors.dart';
import '../labeled_toggle.dart';

part 'tactics_import_panel_start_card.dart';
part 'tactics_import_panel_accounts_card.dart';
part 'tactics_import_panel_widgets.dart';

/// Tactics home screen when no puzzle is active: an always-visible accounts
/// card (usernames front and centre, and which games count as recent), then the
/// Tactics card — what is in the database and the filters that decide which of
/// it you practise.
///
/// What is *not* here any more:
///
/// * An Import button per site and an engine gear. Downloading games, checking
///   them against your books and finding your mistakes are one job, and it
///   belongs beside the games it produces — the review strip in the left pane
///   owns it, including how many cores and how much depth it may use.
/// * The big Start Practice button, and the import/resume status banners. Both
///   have moved to that same strip: two play buttons half a window apart, and a
///   progress banner on the opposite side from the progress bar, is a screen
///   that reads as two unrelated apps. One column starts things and reports on
///   them; this side is what they act on.
///
/// Layout rule: the structure is static. Sections never collapse, reorder,
/// or appear/disappear in reaction to typing.
///
/// The panel renders [TacticsImportForm] directly rather than taking a dozen
/// controller props: the form *is* this card's state, and threading each field
/// through its own parameter only obscured that the two are one thing.
class TacticsImportPanel extends StatefulWidget {
  const TacticsImportPanel({
    super.key,
    required this.form,
    required this.isImporting,
    required this.positions,
    required this.onClearDatabase,
    required this.onBrowseTactics,
    this.clearDatabaseEnabled = true,
  });

  /// Text fields, the shared games window, and the shared engine settings.
  /// Owned by the control panel; this widget only renders it.
  final TacticsImportForm form;

  final bool isImporting;
  final List<TacticsPosition> positions;
  final VoidCallback onClearDatabase;
  final VoidCallback onBrowseTactics;
  final bool clearDatabaseEnabled;

  @override
  State<TacticsImportPanel> createState() => _TacticsImportPanelState();
}

/// Shared state for [TacticsImportPanel]: the fields the card mixins read and
/// mutate. The concrete [_TacticsImportPanelState] applies the card mixins and
/// keeps the lifecycle hooks and [build].
abstract class _TacticsImportPanelStateBase extends State<TacticsImportPanel> {
  final _daysFocus = FocusNode();
  final _gamesFocus = FocusNode();

  TacticsImportForm get _form => widget.form;

  /// The practice filters, owned by [TacticsSessionController] so the left
  /// pane's Study-tactics button can count what they queue up.
  TacticsSessionSettings get _settings =>
      context.read<TacticsSessionController>().sessionSettings;
}

class _TacticsImportPanelState extends _TacticsImportPanelStateBase
    with _TacticsImportPanelStartCard, _TacticsImportPanelAccountsCard {
  @override
  void initState() {
    super.initState();
    // The form keeps the window fields in sync with the shared setting, but
    // must not overwrite whichever one the user is typing in.
    _daysFocus.addListener(
      () => _form.setDaysFieldFocused(_daysFocus.hasFocus),
    );
    _gamesFocus.addListener(
      () => _form.setGamesFieldFocused(_gamesFocus.hasFocus),
    );
    // Restore the user's last-used session settings into the shared controller
    // (save: false — this *is* what was saved).
    unawaited(
      TacticsSessionSettings.load().then((saved) {
        if (!mounted) return;
        context.read<TacticsSessionController>().setSessionSettings(
          saved,
          save: false,
        );
      }),
    );
  }

  @override
  void dispose() {
    _daysFocus.dispose();
    _gamesFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final positionCount = widget.positions.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildAccountsCard(),
        const SizedBox(height: 12),
        _buildStartCard(positionCount),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            _conditionalTooltip(
              message: positionCount == 0 ? 'No tactics to browse' : null,
              child: TextButton.icon(
                onPressed: positionCount > 0 ? widget.onBrowseTactics : null,
                icon: const Icon(Icons.list_alt, size: 16),
                label: const Text('Browse Tactics'),
              ),
            ),
            _conditionalTooltip(
              message: positionCount == 0
                  ? 'No positions in database'
                  : widget.isImporting
                  ? 'Import in progress'
                  : null,
              child: TextButton.icon(
                onPressed: widget.clearDatabaseEnabled && positionCount > 0
                    ? widget.onClearDatabase
                    : null,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Delete All Tactics'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
