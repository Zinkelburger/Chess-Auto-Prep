import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/common/piece_image.dart';
import '../controllers/bughouse_controller.dart';
import '../models/bughouse_state.dart';

/// Position editor: what to place, whose turn it is, what may still castle,
/// and the dual FEN in and out.
class BughouseSetupPanel extends StatefulWidget {
  const BughouseSetupPanel({super.key, required this.controller});

  final BughouseController controller;

  @override
  State<BughouseSetupPanel> createState() => _BughouseSetupPanelState();
}

class _BughouseSetupPanelState extends State<BughouseSetupPanel> {
  final _fenController = TextEditingController();

  @override
  void dispose() {
    _fenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Place pieces', style: AppTextStyles.subtitle),
        const SizedBox(height: 2),
        const Text(
          'Pick a piece, then click a square on either board; right-click a '
          'square to clear it. Click a reserve slot to add one, right-click '
          'to take one away.',
          style: AppTextStyles.caption,
        ),
        const SizedBox(height: 8),
        _Palette(controller: controller),
        const SizedBox(height: 16),

        for (final which in BughouseBoard.values) ...[
          _BoardSetup(controller: controller, which: which),
          const SizedBox(height: 12),
        ],

        const Divider(height: 20),
        const Text('Dual FEN', style: AppTextStyles.subtitle),
        const SizedBox(height: 6),
        TextField(
          controller: _fenController,
          style: AppTextStyles.monoDense,
          maxLines: 3,
          minLines: 2,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            hintText: '<board A fen>|<board B fen>',
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Load'),
              onPressed: () => controller.loadDualFen(_fenController.text),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy current'),
              onPressed: () async {
                final fen = controller.state.dualFen;
                await Clipboard.setData(ClipboardData(text: fen));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Dual FEN copied')),
                );
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.paste, size: 16),
              label: const Text('Paste'),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                final text = data?.text;
                if (text == null) return;
                _fenController.text = text.trim();
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Every piece that can be placed, plus an eraser.
class _Palette extends StatelessWidget {
  const _Palette({required this.controller});

  final BughouseController controller;

  static const _roles = [
    Role.king,
    Role.queen,
    Role.rook,
    Role.bishop,
    Role.knight,
    Role.pawn,
  ];

  @override
  Widget build(BuildContext context) {
    final tool = controller.tool;
    return Column(
      children: [
        for (final side in Side.values)
          Row(
            children: [
              for (final role in _roles)
                _PaletteSlot(
                  selected:
                      tool is PlaceTool &&
                      tool.piece.color == side &&
                      tool.piece.role == role,
                  onTap: () => controller.setTool(
                    PlaceTool(Piece(color: side, role: role)),
                  ),
                  child: PieceImage(
                    piece: Piece(color: side, role: role),
                    size: 28,
                  ),
                ),
              if (side == Side.black) ...[
                const Spacer(),
                _PaletteSlot(
                  selected: tool is EraseTool,
                  onTap: () => controller.setTool(const EraseTool()),
                  child: const Icon(Icons.backspace_outlined, size: 20),
                ),
              ],
            ],
          ),
      ],
    );
  }
}

class _PaletteSlot extends StatelessWidget {
  const _PaletteSlot({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceHighlight : AppColors.surfaceInset,
          borderRadius: BorderRadius.circular(4),
          border: selected
              ? Border.all(color: Theme.of(context).colorScheme.primary)
              : null,
        ),
        child: child,
      ),
    );
  }
}

/// Per-board: side to move, castling rights, clear / reset.
class _BoardSetup extends StatelessWidget {
  const _BoardSetup({required this.controller, required this.which});

  final BughouseController controller;
  final BughouseBoard which;

  @override
  Widget build(BuildContext context) {
    final position = controller.state.board(which);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(which.label, style: AppTextStyles.bodyStrong),
        const SizedBox(height: 4),
        Row(
          children: [
            const SizedBox(
              width: 78,
              child: Text('To move', style: AppTextStyles.caption),
            ),
            SegmentedButton<Side>(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: Side.white, label: Text('White')),
                ButtonSegment(value: Side.black, label: Text('Black')),
              ],
              selected: {position.turn},
              onSelectionChanged: (s) => controller.setTurn(which, s.first),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 78,
              child: Text('Castling', style: AppTextStyles.caption),
            ),
            Expanded(
              child: Wrap(
                spacing: 4,
                children: [
                  for (final side in Side.values)
                    for (final castling in CastlingSide.values)
                      _CastlingChip(
                        controller: controller,
                        which: which,
                        side: side,
                        castlingSide: castling,
                      ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const SizedBox(width: 78),
            OutlinedButton(
              onPressed: () => controller.resetBoard(which),
              child: const Text('Start position'),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: () => controller.clearBoard(which),
              child: const Text('Clear'),
            ),
          ],
        ),
      ],
    );
  }
}

class _CastlingChip extends StatelessWidget {
  const _CastlingChip({
    required this.controller,
    required this.which,
    required this.side,
    required this.castlingSide,
  });

  final BughouseController controller;
  final BughouseBoard which;
  final Side side;
  final CastlingSide castlingSide;

  @override
  Widget build(BuildContext context) {
    final castles = controller.state.board(which).castles;
    final enabled = castles.rookOf(side, castlingSide) != null;
    // K/Q for white, k/q for black — the FEN letters, which is what a player
    // reading a position expects to see.
    final letter = castlingSide == CastlingSide.king ? 'K' : 'Q';
    final label = side == Side.white ? letter : letter.toLowerCase();

    return FilterChip(
      label: Text(label, style: AppTextStyles.monoDense),
      selected: enabled,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (value) =>
          controller.setCastlingRight(which, side, castlingSide, value),
    );
  }
}
