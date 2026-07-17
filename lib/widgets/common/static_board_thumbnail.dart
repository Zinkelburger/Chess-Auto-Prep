/// Cheap, non-interactive board previews for list rows.
library;

import 'dart:ui' as ui;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../theme/app_colors.dart';
import '../../utils/chess_utils.dart' show roleChar;

/// A static board preview that stays cheap in long lists.
///
/// Unlike `ChessBoardWidget` (a stateful interactive board with gesture
/// machinery and one SVG child per piece, which also needs a fully validated
/// `Position` via `Chess.fromSetup`), this parses only the piece-placement
/// field of the FEN and paints the entire board — squares and pieces — as a
/// single `CustomPaint` using piece sprites rasterized once and shared by
/// every thumbnail in the app.
///
/// Oriented so the side to move is at the bottom (same perspective as
/// training) when the FEN carries a turn field.
class StaticBoardThumbnail extends StatefulWidget {
  const StaticBoardThumbnail({super.key, required this.fen, this.size = 60});

  final String fen;
  final double size;

  @override
  State<StaticBoardThumbnail> createState() => _StaticBoardThumbnailState();
}

class _StaticBoardThumbnailState extends State<StaticBoardThumbnail> {
  Board? _board;
  bool _flipped = false;

  @override
  void initState() {
    super.initState();
    _parse();
    if (!_PieceSprites.isLoaded) {
      _PieceSprites.ensureLoaded().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(covariant StaticBoardThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fen != widget.fen) _parse();
  }

  void _parse() {
    try {
      final fields = widget.fen.trim().split(' ');
      _board = Board.parseFen(fields[0]);
      _flipped = fields.length > 1 && fields[1] == 'b';
    } catch (_) {
      _board = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = _board;
    if (board == null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Icon(
          Icons.broken_image_outlined,
          size: 20,
          color: AppColors.onSurfaceMuted,
        ),
      );
    }
    return SizedBox(
      width: widget.size,
      height: widget.size,
      // Keep the board raster out of the enclosing list's scroll repaints.
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _ThumbnailPainter(
            board: board,
            flipped: _flipped,
            spritesLoaded: _PieceSprites.isLoaded,
          ),
          size: Size.square(widget.size),
        ),
      ),
    );
  }
}

class _ThumbnailPainter extends CustomPainter {
  _ThumbnailPainter({
    required this.board,
    required this.flipped,
    required this.spritesLoaded,
  });

  final Board board;
  final bool flipped;
  final bool spritesLoaded;

  @override
  void paint(Canvas canvas, Size size) {
    final squareSize = size.width / 8;
    final paint = Paint();

    for (int file = 0; file < 8; file++) {
      for (int rank = 0; rank < 8; rank++) {
        final col = flipped ? 7 - file : file;
        final row = flipped ? rank : 7 - rank;
        paint.color = (file + rank) % 2 != 0
            ? AppColors.boardLightSquare
            : AppColors.boardDarkSquare;
        canvas.drawRect(
          Rect.fromLTWH(
            col * squareSize,
            row * squareSize,
            squareSize,
            squareSize,
          ),
          paint,
        );
      }
    }

    if (spritesLoaded) {
      final piecePaint = Paint()..filterQuality = FilterQuality.medium;
      for (final (square, piece) in board.pieces) {
        final sprite = _PieceSprites.spriteFor(piece);
        if (sprite == null) continue;
        final col = flipped ? 7 - square.file : square.file;
        final row = flipped ? square.rank : 7 - square.rank;
        canvas.drawImageRect(
          sprite,
          Rect.fromLTWH(
            0,
            0,
            sprite.width.toDouble(),
            sprite.height.toDouble(),
          ),
          Rect.fromLTWH(
            col * squareSize,
            row * squareSize,
            squareSize,
            squareSize,
          ),
          piecePaint,
        );
      }
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = AppColors.boardOutline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _ThumbnailPainter old) =>
      board != old.board ||
      flipped != old.flipped ||
      spritesLoaded != old.spritesLoaded;
}

/// Piece sprites rasterized from the bundled SVGs once per app session and
/// shared by every [StaticBoardThumbnail].
class _PieceSprites {
  static const int _rasterSize = 48;
  static final Map<String, ui.Image> _sprites = {};
  static Future<void>? _pending;

  static bool get isLoaded => _sprites.isNotEmpty;

  static ui.Image? spriteFor(Piece piece) {
    final color = piece.color == Side.white ? 'w' : 'b';
    return _sprites['$color${roleChar(piece.role)}'];
  }

  static Future<void> ensureLoaded() => _pending ??= _loadAll();

  static Future<void> _loadAll() async {
    for (final color in const ['w', 'b']) {
      for (final type in const ['K', 'Q', 'R', 'B', 'N', 'P']) {
        final key = '$color$type';
        try {
          _sprites[key] = await _rasterize('assets/pieces/$key.svg');
        } catch (_) {
          // Missing/undecodable asset: thumbnails render without this piece.
        }
      }
    }
  }

  static Future<ui.Image> _rasterize(String assetPath) async {
    final info = await vg.loadPicture(SvgAssetLoader(assetPath), null);
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final scale =
          _rasterSize /
          (info.size.width > info.size.height
              ? info.size.width
              : info.size.height);
      canvas.scale(scale);
      canvas.drawPicture(info.picture);
      return await recorder.endRecording().toImage(_rasterSize, _rasterSize);
    } finally {
      info.picture.dispose();
    }
  }
}
