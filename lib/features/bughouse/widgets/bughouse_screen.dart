/// Bughouse Lab: two linked boards, a position editor, and a neural-network
/// engine that reasons about both boards at once.
///
/// Bughouse is not chess with extra rules — it is a four-player, two-board,
/// real-time team game, and the pane is shaped by the four ways that shows:
///
///   * A captured piece goes to the *other* board, keeping its colour. Both
///     boards and all four reserves are on screen because that flow is the
///     whole game.
///   * Four people play, so each board is a column holding two of them: their
///     seat, their reserve and their clock stacked around the board they sit
///     at. Nothing about a player is filed anywhere else.
///   * The engine returns a *joint* action, one decision per board, and `pass`
///     (sitting) is a first-class move. Both teams are searched, always: a
///     bughouse position has no single side to move, so "what should I play"
///     and "what are they about to play" are two searches, not one.
///   * Whether the team is ahead on the diagonal clock changes what is legal,
///     so it is an explicit control rather than something inferred.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/keyboard_shortcut_utils.dart';
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

  /// Holds the keyboard so the arrow keys walk the line, the way they do on
  /// any analysis board. Focus is taken when the pane comes on screen and
  /// given up freely — typing in a clock or a FEN field has to win.
  final FocusNode _keys = FocusNode(debugLabel: 'bughouse-keys');

  bool _wasOnScreen = false;

  @override
  void dispose() {
    _keys.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mode views are built once and kept in an `IndexedStack` for the life of
    // the app, so this widget is still mounted and still building when the
    // user is somewhere else entirely. The engine has to be told, or it keeps
    // a neural-network search running on every core in a mode nobody is
    // looking at.
    final onScreen = context.select<AppState, bool>(
      (state) => state.currentMode == AppMode.bughouse,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.setOnScreen(onScreen);
      // Only on the way in: stealing focus on every frame would fight every
      // text field on the pane.
      if (onScreen && !_wasOnScreen) _keys.requestFocus();
      _wasOnScreen = onScreen;
    });

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
          body: CallbackShortcuts(
            bindings: {
              // Every binding defers to a text field with focus: `f`, `g` and
              // space are letters someone types into a clock or a FEN, and
              // the arrows move the caret there. The app's other boards make
              // the same check.
              const SingleActivator(LogicalKeyboardKey.arrowLeft):
                  _unlessTyping(controller.back),
              const SingleActivator(LogicalKeyboardKey.arrowRight):
                  _unlessTyping(controller.forward),
              const SingleActivator(LogicalKeyboardKey.home): _unlessTyping(
                controller.toStart,
              ),
              const SingleActivator(LogicalKeyboardKey.end): _unlessTyping(
                controller.toEnd,
              ),
              const SingleActivator(LogicalKeyboardKey.keyF): _unlessTyping(
                () => controller.toggleFlip(BughouseBoard.a),
              ),
              const SingleActivator(LogicalKeyboardKey.keyG): _unlessTyping(
                () => controller.toggleFlip(BughouseBoard.b),
              ),
              const SingleActivator(LogicalKeyboardKey.space): _unlessTyping(
                () =>
                    controller.setAnalysisEnabled(!controller.analysisEnabled),
              ),
            },
            child: Focus(
              focusNode: _keys,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Below this the two boards plus a panel stop fitting side by
                  // side, and stacking beats shrinking all three.
                  final stacked = constraints.maxWidth < 1120;
                  final side = _SidePanel(controller: controller);

                  if (stacked) {
                    return ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        _Boards(
                          controller: controller,
                          boardWidth: _Boards.fit(
                            width: constraints.maxWidth - 24,
                            // Stacked, the column scrolls, so height stops
                            // bounding the board and width alone decides.
                            height: double.infinity,
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(height: 560, child: side),
                      ],
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            child: _Boards(
                              controller: controller,
                              boardWidth: _Boards.fit(
                                width: constraints.maxWidth - 24 - 16 - 400,
                                height: constraints.maxHeight - 24,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(width: 400, child: side),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A shortcut that stands down while a text field has the keyboard.
VoidCallback _unlessTyping(VoidCallback action) => () {
  if (isTextInputFocused()) return;
  action();
};

/// The two boards side by side, and the one control that spans them.
class _Boards extends StatelessWidget {
  const _Boards({required this.controller, required this.boardWidth});

  final BughouseController controller;

  /// How wide each board is drawn. Decided by the pane rather than by the
  /// card, because the constraint is about the *pair* of them.
  final double boardWidth;

  /// Two boards and four reserves is already a lot to hold at once. Capping
  /// the board keeps the pair readable as one table on a wide display instead
  /// of two billboards, and leaves the eye somewhere to rest between them.
  static const _maxBoardWidth = 400.0;

  /// Below this a board stops being a board.
  static const _minBoardWidth = 240.0;

  /// Everything stacked above and below a board inside its column, plus the
  /// line controls under the pair: two seat rows, two reserves, the header,
  /// the movetext and the gaps between them.
  ///
  /// A board is square, so its width is bounded by the height left over once
  /// all of that is accounted for — the same reasoning the repertoire builder
  /// uses. Without it the boards took their full width and pushed the seat
  /// rows, the reserves and the movetext off the bottom of the window, which
  /// is exactly the content that makes the pane worth looking at.
  ///
  /// It is a constant because every part of it is: the movetext has a fixed
  /// height for this reason, so the boards do not resize as the game is
  /// played. Measured against the built pane rather than guessed.
  static const double chromeHeight =
      24 +
      6 +
      30 +
      46 +
      6 +
      6 +
      46 +
      30 +
      8 +
      BughouseBoardMovetext.height +
      4 +
      36;

  /// The largest board that fits both ways.
  static double fit({required double width, required double height}) {
    final byWidth = (width - _gap) / 2;
    final byHeight = height - chromeHeight;
    final natural = byWidth < byHeight ? byWidth : byHeight;
    return natural.clamp(_minBoardWidth, _maxBoardWidth).toDouble();
  }

  static const double _gap = 24;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final which in BughouseBoard.values) ...[
              if (which == BughouseBoard.b) const SizedBox(width: _gap),
              SizedBox(
                width: boardWidth,
                child: BughouseBoardCard(controller: controller, which: which),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        BughouseLineControls(controller: controller),
      ],
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
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Setting a position up is a thing you do once; reading the engine
            // is what the pane is for. So the switch between them is a text
            // button in the corner rather than the first control on the panel,
            // and the score gets the top of the column.
            Row(
              children: [
                Expanded(
                  child: Text(
                    setup ? 'EDITING THE POSITION' : 'HIVEMIND',
                    style: AppTextStyles.eyebrow,
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: AppTextStyles.caption,
                    foregroundColor: AppColors.onSurfaceMuted,
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
            Expanded(
              child: setup
                  ? SingleChildScrollView(
                      child: BughouseSetupPanel(controller: controller),
                    )
                  : BughouseAnalysisPanel(controller: controller),
            ),
          ],
        ),
      ),
    );
  }
}
