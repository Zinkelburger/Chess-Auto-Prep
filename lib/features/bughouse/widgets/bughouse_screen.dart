/// Bughouse Lab: two linked boards, a position editor, and a neural-network
/// engine that reasons about both boards at once.
///
/// Bughouse is not chess with extra rules — it is a four-player, two-board,
/// real-time team game, and the pane is shaped by the three ways that shows:
///
///   * A captured piece goes to the *other* board, keeping its colour. Both
///     boards and all four reserves are on screen because that flow is the
///     whole game.
///   * The engine returns a *joint* action, one decision per board, and `pass`
///     (sitting) is a first-class move. Both teams are searched, always: a
///     bughouse position has no single side to move, so "what should I play"
///     and "what are they about to play" are two searches, not one.
///   * Whether the team is ahead on the diagonal clock changes what is legal,
///     so it is an explicit control rather than something inferred.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../theme/app_text_styles.dart';
import '../../../widgets/app_breadcrumb_trail.dart';
import '../../../widgets/app_mode_switcher.dart';
import '../../../widgets/app_settings_button.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_state.dart';
import 'bughouse_analysis_panel.dart';
import 'bughouse_board_card.dart';
import 'bughouse_move_list.dart';
import 'bughouse_setup_panel.dart';

class BughouseScreen extends StatefulWidget {
  const BughouseScreen({super.key, this.controller});

  /// Controller to use instead of making one. Tests only.
  @visibleForTesting
  final BughouseController? controller;

  @override
  State<BughouseScreen> createState() => _BughouseScreenState();
}

class _BughouseScreenState extends State<BughouseScreen> {
  late final BughouseController _controller =
      widget.controller ?? BughouseController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _controller,
      child: Consumer<BughouseController>(
        builder: (context, controller, _) => Scaffold(
          appBar: AppBar(
            title: const AppBreadcrumbTrail(),
            actions: [
              TextButton.icon(
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('New game'),
                onPressed: controller.newGame,
              ),
              const AppModeSwitcher(),
              const AppSettingsButton(),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 1000;
              final boards = _Boards(controller: controller, stacked: stacked);
              final side = _SidePanel(controller: controller);

              if (stacked) {
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: [boards, const SizedBox(height: 12), side],
                );
              }
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: SingleChildScrollView(child: boards)),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 380,
                      child: SingleChildScrollView(child: side),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Boards extends StatelessWidget {
  const _Boards({required this.controller, required this.stacked});

  final BughouseController controller;
  final bool stacked;

  /// Two boards and four reserves is already a lot to hold at once. Capping
  /// the board keeps the pair readable as one table on a wide display instead
  /// of two billboards, and leaves the eye somewhere to rest between them.
  static const _maxBoardWidth = 420.0;

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (final which in BughouseBoard.values)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxBoardWidth),
          child: BughouseBoardCard(controller: controller, which: which),
        ),
    ];
    if (stacked) {
      return Column(children: [cards[0], const SizedBox(height: 20), cards[1]]);
    }
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(child: cards[0]),
          const SizedBox(width: 28),
          Flexible(child: cards[1]),
        ],
      ),
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.controller});

  final BughouseController controller;

  @override
  Widget build(BuildContext context) {
    final setup = controller.mode == BughouseMode.setup;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Setting a position up is a thing you do once; reading the
            // engine is what the pane is for. So the switch between them is a
            // text button in the corner rather than the first control on the
            // panel, and the score gets the top of the column.
            Row(
              children: [
                Expanded(
                  child: Text(
                    setup
                        ? 'Editing the position'
                        : 'Hivemind${controller.backendLabel.isEmpty ? '' : ' · ${controller.backendLabel}'}',
                    style: AppTextStyles.caption,
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: AppTextStyles.caption,
                  ),
                  icon: Icon(setup ? Icons.check : Icons.edit, size: 14),
                  label: Text(setup ? 'Done' : 'Edit position'),
                  onPressed: () => controller.setMode(
                    setup ? BughouseMode.play : BughouseMode.setup,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (setup)
              BughouseSetupPanel(controller: controller)
            else ...[
              BughouseAnalysisPanel(controller: controller),
              const Divider(height: 24),
              BughouseMoveList(controller: controller),
            ],
          ],
        ),
      ),
    );
  }
}
