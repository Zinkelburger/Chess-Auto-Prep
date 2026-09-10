import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../utils/chess_utils.dart' show fenAfterMoves, sanToUci;
import '../../../widgets/common/static_board_thumbnail.dart';

/// The position before leaving the book, using the same arrows as game cards.
class OpeningPositionPreview extends StatelessWidget {
  const OpeningPositionPreview({
    super.key,
    required this.pathSans,
    required this.playedSan,
    required this.expectedSans,
    required this.byMe,
    this.bookEnded = false,
    this.flipped,
    this.size = 120,
  });

  final List<String> pathSans;
  final String? playedSan;
  final List<String> expectedSans;
  final bool byMe;
  final bool bookEnded;
  final bool? flipped;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fen = fenAfterMoves(Chess.initial.fen, pathSans, pathSans.length - 1);
    final played = playedSan == null ? null : sanToUci(fen, playedSan!);
    final playedColor = byMe && !bookEnded
        ? AppColors.danger
        : AppColors.onSurfaceMuted;
    return Semantics(
      image: true,
      label:
          'Position before ${playedSan ?? 'the end of the line'}. '
          '${byMe ? 'You' : 'They'} played ${playedSan ?? 'no move'}. '
          '${expectedSans.isEmpty ? 'Book ends here.' : 'Book moves: ${expectedSans.join(', ')}.'}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: StaticBoardThumbnail(
          fen: fen,
          size: size,
          flipped: flipped,
          arrows: [
            for (final san in expectedSans)
              if (sanToUci(fen, san) case final String uci)
                BoardArrow(
                  uci: uci,
                  color: AppColors.success.withValues(alpha: 0.85),
                ),
            if (played != null)
              BoardArrow(
                uci: played,
                color: playedColor.withValues(alpha: 0.9),
              ),
          ],
        ),
      ),
    );
  }
}
