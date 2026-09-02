/// Cheap, non-interactive board previews for list rows.
library;

import 'dart:async';

import 'dart:ui' as ui;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../theme/app_colors.dart';
import '../../utils/fen_utils.dart';
import '../../utils/chess_utils.dart' show roleChar;

/// One move drawn over a [StaticBoardThumbnail], from-square to to-square.
@immutable
class BoardArrow {
  const BoardArrow({required this.uci, required this.color});

  /// Standard UCI ("e2e4"; promotions carry a fifth character that is
  /// ignored here). Anything that does not parse as two squares draws nothing.
  final String uci;
  final Color color;

  Square? get from => _square(uci, 0);
  Square? get to => _square(uci, 2);

  static Square? _square(String uci, int at) {
    if (uci.length < at + 2) return null;
    return Square.parse(uci.substring(at, at + 2));
  }

  @override
  bool operator ==(Object other) =>
      other is BoardArrow && other.uci == uci && other.color == color;

  @override
  int get hashCode => Object.hash(uci, color);
}

/// A static board preview that stays cheap in long lists.
///
/// Unlike `ChessBoardWidget` (a stateful interactive board with gesture
/// machinery and one SVG child per piece, which also needs a fully validated
/// `Position` via `Chess.fromSetup`), this parses only the piece-placement
/// field of the FEN and paints the entire board — squares and pieces — as a
/// single `CustomPaint` using piece sprites rasterized to the resolution this
/// board actually needs and shared by every thumbnail asking for that size.
///
/// Oriented so the side to move is at the bottom (same perspective as
/// training) when the FEN carries a turn field — pass [flipped] to override,
/// e.g. a games list that always shows the position from *my* side.
///
/// [arrows] draws moves over the position — the move that was played, the
/// move the book wanted — so a thumbnail can show a *moment* rather than
/// just a position. Drawn in list order, so put the one that should win an
/// overlap last.
class StaticBoardThumbnail extends StatefulWidget {
  const StaticBoardThumbnail({
    super.key,
    required this.fen,
    this.size = 60,
    this.flipped,
    this.arrows = const [],
  });

  final String fen;
  final double size;

  /// True = Black at the bottom. Null derives it from the FEN's turn field.
  final bool? flipped;

  final List<BoardArrow> arrows;

  @override
  State<StaticBoardThumbnail> createState() => _StaticBoardThumbnailState();
}

class _StaticBoardThumbnailState extends State<StaticBoardThumbnail> {
  Board? _board;
  bool _flipped = false;

  /// Raster size, in device pixels, of the sprite set this thumbnail draws.
  int _bucket = _PieceSprites.smallestBucket;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureSprites();
  }

  @override
  void didUpdateWidget(covariant StaticBoardThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fen != widget.fen || oldWidget.flipped != widget.flipped) {
      _parse();
    }
    if (oldWidget.size != widget.size) _ensureSprites();
  }

  /// Pick the sprite resolution this thumbnail actually needs and load it.
  ///
  /// Runs from [didChangeDependencies] as well as on resize because the bucket
  /// depends on `devicePixelRatio` — dragging the window to a monitor with a
  /// different scale has to re-pick, or the board keeps drawing sprites cut for
  /// the old display.
  void _ensureSprites() {
    final squareDevicePx =
        widget.size / 8 * MediaQuery.devicePixelRatioOf(context);
    final bucket = _PieceSprites.bucketFor(squareDevicePx);
    if (bucket == _bucket && _PieceSprites.isLoaded(bucket)) return;
    _bucket = bucket;
    if (_PieceSprites.isLoaded(bucket)) {
      setState(() {});
      return;
    }
    unawaited(
      _PieceSprites.ensureLoaded(bucket).then((_) {
        if (mounted && _bucket == bucket) setState(() {});
      }),
    );
  }

  void _parse() {
    try {
      final fen = widget.fen.trim();
      _board = Board.parseFen(fen.split(' ').first);
      _flipped = widget.flipped ?? !isWhiteToMove(fen);
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
            bucket: _bucket,
            spritesLoaded: _PieceSprites.isLoaded(_bucket),
            arrows: widget.arrows,
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
    required this.bucket,
    required this.spritesLoaded,
    required this.arrows,
  });

  final Board board;
  final bool flipped;
  final int bucket;
  final bool spritesLoaded;
  final List<BoardArrow> arrows;

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
        final sprite = _PieceSprites.spriteFor(bucket, piece);
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

    for (final arrow in arrows) {
      _drawArrow(canvas, arrow, squareSize);
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = AppColors.boardOutline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  Offset _center(Square square, double squareSize) {
    final col = flipped ? 7 - square.file : square.file;
    final row = flipped ? square.rank : 7 - square.rank;
    return Offset((col + 0.5) * squareSize, (row + 0.5) * squareSize);
  }

  /// A shaft with a filled head, sized to the square so it reads at any
  /// thumbnail size: the shaft is a sixth of a square wide, the head a bit
  /// over half a square long, and the shaft stops where the head begins so
  /// the two never show through each other at partial opacity.
  void _drawArrow(Canvas canvas, BoardArrow arrow, double squareSize) {
    final from = arrow.from;
    final to = arrow.to;
    if (from == null || to == null || from == to) return;
    final start = _center(from, squareSize);
    final end = _center(to, squareSize);
    final direction = end - start;
    final length = direction.distance;
    final unit = direction / length;
    final headLength = squareSize * 0.55;
    final headWidth = squareSize * 0.45;
    final shaftWidth = squareSize / 6;
    // Start a little into the from-square so the arrow reads as leaving the
    // piece rather than being pinned through its middle.
    final shaftStart = start + unit * (squareSize * 0.2);
    final headBase = end - unit * headLength;
    final paint = Paint()
      ..color = arrow.color
      ..style = PaintingStyle.fill;
    if (length > headLength + squareSize * 0.2) {
      canvas.drawLine(
        shaftStart,
        headBase,
        Paint()
          ..color = arrow.color
          ..strokeWidth = shaftWidth
          ..strokeCap = StrokeCap.round,
      );
    }
    final normal = Offset(-unit.dy, unit.dx) * (headWidth / 2);
    canvas.drawPath(
      Path()
        ..moveTo(end.dx, end.dy)
        ..lineTo(headBase.dx + normal.dx, headBase.dy + normal.dy)
        ..lineTo(headBase.dx - normal.dx, headBase.dy - normal.dy)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ThumbnailPainter old) =>
      board != old.board ||
      flipped != old.flipped ||
      bucket != old.bucket ||
      spritesLoaded != old.spritesLoaded ||
      !listEquals(arrows, old.arrows);
}

/// Smallest sprite raster, in device pixels, that covers a square of
/// [squareDevicePx] without being upscaled.
///
/// Exposed so a test can pin the property that actually matters: the chosen
/// raster is never smaller than the square it has to fill.
@visibleForTesting
int spriteBucketFor(double squareDevicePx) =>
    _PieceSprites.bucketFor(squareDevicePx);

/// The largest raster [spriteBucketFor] will hand out.
@visibleForTesting
int get maxSpriteBucket => _PieceSprites.largestBucket;

/// Piece sprites rasterized from the bundled SVGs, one set per raster size,
/// shared by every [StaticBoardThumbnail] that needs that size.
class _PieceSprites {
  /// Raster sizes we are willing to keep, in **device** pixels per square.
  ///
  /// A thumbnail takes the smallest bucket that covers its square, so a sprite
  /// is only ever scaled *down*. The previous single hard-coded 48px raster
  /// had no notion of `devicePixelRatio`: on a 2x display a 144px game-card
  /// board wants 36 device pixels a square and got away with it, but anything
  /// larger — or any display past 2.67x — was blowing a 48px bitmap up past
  /// 1:1, which is genuine pixelation and looked exactly like it.
  ///
  /// The floor stays at that same 48 so nothing that looks right today gets a
  /// *smaller* sprite than it already has; the larger buckets are what a
  /// scaled display or a bigger preview now reaches for.
  static const List<int> _buckets = [48, 96, 192, 384];

  static int get smallestBucket => _buckets.first;

  static int get largestBucket => _buckets.last;

  static final Map<int, Map<String, ui.Image>> _sprites = {};
  static final Map<int, Future<void>> _pending = {};
  static final Set<int> _loaded = {};

  /// Smallest raster that covers [squareDevicePx] without being upscaled.
  ///
  /// Past the largest bucket we stop growing rather than rasterize unbounded —
  /// a square that big is a real board, not a thumbnail, and belongs in
  /// `ChessBoardWidget`, which draws the SVGs as vectors at any size.
  static int bucketFor(double squareDevicePx) {
    for (final bucket in _buckets) {
      if (bucket >= squareDevicePx) return bucket;
    }
    return _buckets.last;
  }

  /// True only once *every* sprite in [bucket] has been rasterized.
  ///
  /// Deliberately not `_sprites.isNotEmpty`. The sprites land one at a time,
  /// so any thumbnail built mid-load used to see this as `true`, paint the
  /// pieces that happened to exist, skip the rest (`spriteFor` returns null),
  /// and — having decided the sprites were ready — never register for the
  /// repaint that would have fixed it. Black is rasterized after White, so
  /// what that produced was a board with no black pieces, permanently.
  static bool isLoaded(int bucket) => _loaded.contains(bucket);

  static ui.Image? spriteFor(int bucket, Piece piece) {
    final color = piece.color == Side.white ? 'w' : 'b';
    return _sprites[bucket]?['$color${roleChar(piece.role)}'];
  }

  static Future<void> ensureLoaded(int bucket) =>
      _pending[bucket] ??= _loadAll(bucket);

  /// All twelve at once rather than one after another: each is an independent
  /// asset read, and doing them serially stretched the window in which a list
  /// paints boards with pieces missing from milliseconds to a visible beat.
  static Future<void> _loadAll(int bucket) async {
    final into = _sprites[bucket] ??= {};
    await Future.wait([
      for (final color in const ['w', 'b'])
        for (final type in const ['K', 'Q', 'R', 'B', 'N', 'P'])
          _rasterizeInto(into, '$color$type', bucket),
    ]);
    _loaded.add(bucket);
  }

  static Future<void> _rasterizeInto(
    Map<String, ui.Image> into,
    String key,
    int bucket,
  ) async {
    try {
      into[key] = await _rasterize('assets/pieces/$key.svg', bucket);
    } catch (_) {
      // Missing/undecodable asset: thumbnails render without this piece.
    }
  }

  static Future<ui.Image> _rasterize(String assetPath, int rasterSize) async {
    final info = await vg.loadPicture(SvgAssetLoader(assetPath), null);
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final scale =
          rasterSize /
          (info.size.width > info.size.height
              ? info.size.width
              : info.size.height);
      canvas.scale(scale);
      canvas.drawPicture(info.picture);
      return await recorder.endRecording().toImage(rasterSize, rasterSize);
    } finally {
      info.picture.dispose();
    }
  }
}
