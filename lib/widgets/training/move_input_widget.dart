/// Keyboard move entry for the repertoire trainer.
///
/// Accepts SAN (e.g. "Nf6", "e4", "O-O") or UCI (e.g. "g8f6", "e2e4").
/// Auto-submits as soon as the typed text uniquely resolves to a legal move.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess_board_widget.dart';
import '../../utils/chess_utils.dart'
    show toAlgebraic, isCastlingMove, castlingKingDestination;

/// A compact text field that lets the user type a move instead of dragging.
///
/// The widget builds a lookup table of every legal move in both SAN and UCI
/// forms. On every keystroke it checks whether the current input is an exact
/// (case-insensitive) match for exactly one legal move — if so it fires
/// [onMove] immediately without requiring Enter.
class MoveInputWidget extends StatefulWidget {
  final Position position;
  final void Function(CompletedMove move) onMove;
  final bool enabled;

  const MoveInputWidget({
    super.key,
    required this.position,
    required this.onMove,
    this.enabled = true,
  });

  @override
  State<MoveInputWidget> createState() => MoveInputWidgetState();
}

class MoveInputWidgetState extends State<MoveInputWidget> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String? _error;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      _controller.clear();
      setState(() => _error = null);
      _focusNode.unfocus();
      return KeyEventResult.handled;
    }

    // Space can never be part of a chess move — let it bubble up to the
    // parent shortcut handler (e.g. "Show Solution" in tactics).
    if (key == LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }

    // Tab blurs the input, returning keyboard control to the panel shortcuts.
    if (key == LogicalKeyboardKey.tab) {
      _focusNode.unfocus();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// All legal moves keyed by their normalised SAN and UCI representations.
  /// Built once per position change.
  late List<LegalMoveEntry> _legalMoves;

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = _handleKeyEvent;
    _legalMoves = _buildLegalMoves(widget.position);
  }

  @override
  void didUpdateWidget(covariant MoveInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.position.fen != oldWidget.position.fen) {
      _legalMoves = _buildLegalMoves(widget.position);
      _controller.clear();
      _error = null;
    }
    if (widget.enabled && !oldWidget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focusNode.canRequestFocus) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Focus the text field programmatically (e.g. after opponent moves).
  void focus() {
    if (_focusNode.canRequestFocus) _focusNode.requestFocus();
  }

  /// Blur the text field, returning keyboard control to parent shortcuts.
  void unfocus() {
    _focusNode.unfocus();
  }

  // ---------------------------------------------------------------------------
  // Build legal-move lookup
  // ---------------------------------------------------------------------------

  static List<LegalMoveEntry> _buildLegalMoves(Position position) {
    final entries = <LegalMoveEntry>[];
    final legalMoves = position.legalMoves;

    for (final fromSq in legalMoves.keys) {
      final targets = legalMoves[fromSq];
      if (targets == null) continue;

      for (final toSq in targets.squares) {
        final piece = position.board.pieceAt(fromSq);
        final isPromotion = piece?.role == Role.pawn &&
            ((piece!.color == Side.white && toSq ~/ 8 == 7) ||
                (piece.color == Side.black && toSq ~/ 8 == 0));

        final promotionRoles =
            isPromotion ? [Role.queen, Role.knight, Role.rook, Role.bishop] : [null];

        for (final promo in promotionRoles) {
          final move = NormalMove(from: fromSq, to: toSq, promotion: promo);
          try {
            final (newPos, san) = position.makeSan(move);

            final from = toAlgebraic(fromSq);
            final to = toAlgebraic(toSq);
            final promoChar = promo != null ? _roleToLower(promo) : '';
            final uci = '$from$to$promoChar';

            // For castling, dartchess encodes king→rook-square (e.g. e1h1).
            // Also accept the standard UCI king→destination (e.g. e1g1).
            final uciAliases = <String>[uci];
            if (isCastlingMove(position, fromSq, toSq)) {
              final kingDest =
                  castlingKingDestination(position, fromSq, toSq);
              uciAliases.add('$from${toAlgebraic(kingDest)}');
            }

            entries.add(LegalMoveEntry(
              san: san,
              uciAliases: uciAliases,
              from: from,
              to: to,
              fenBefore: position.fen,
              fenAfter: newPos.fen,
            ));
          } catch (_) {
            // skip illegal moves
          }
        }
      }
    }
    return entries;
  }

  static String _roleToLower(Role role) => switch (role) {
        Role.queen => 'q',
        Role.knight => 'n',
        Role.bishop => 'b',
        Role.rook => 'r',
        Role.pawn => '',
        Role.king => 'k',
      };

  // ---------------------------------------------------------------------------
  // Input handling
  // ---------------------------------------------------------------------------

  void _onChanged(String value) {
    if (value.isEmpty) {
      setState(() => _error = null);
      return;
    }

    final input = value.trim();
    final match = _findExactMatch(input);
    if (match != null) {
      _controller.clear();
      setState(() => _error = null);
      widget.onMove(CompletedMove(
        from: match.from,
        to: match.to,
        san: match.san,
        fenBefore: match.fenBefore,
        fenAfter: match.fenAfter,
        uci: match.uci,
      ));
      return;
    }

    // Check if input is a valid prefix of at least one move
    final hasPrefix = _hasMatchingPrefix(input);
    setState(() {
      _error = hasPrefix ? null : 'No matching move';
    });
  }

  /// Returns a match if [input] uniquely identifies exactly one legal move.
  LegalMoveEntry? _findExactMatch(String input) {
    final stripped = _stripAnnotations(input);
    final lower = stripped.toLowerCase();
    final castlingNorm = _castlingNormalize(lower);

    // 1. Case-sensitive SAN match first (capital letter disambiguates pieces)
    final caseSensitive = _legalMoves
        .where((e) => _stripAnnotations(e.san) == stripped)
        .toList();
    if (caseSensitive.length == 1) return caseSensitive.first;

    // 2. Case-insensitive SAN match
    final sanMatches = _legalMoves
        .where((e) => _normalizeSan(e.san) == castlingNorm)
        .toList();
    if (sanMatches.length == 1) return sanMatches.first;

    // 3. UCI match (checks all aliases, e.g. castling e1h1 and e1g1)
    final uciMatches = _legalMoves
        .where((e) => e.matchesUci(lower))
        .toList();
    if (uciMatches.length == 1) return uciMatches.first;

    // 4. UCI promotion shorthand: "e7e8" without piece → default to queen
    if (uciMatches.isEmpty && lower.length == 4) {
      final queenPromo = _legalMoves
          .where((e) =>
              e.uciStartsWith(lower) && e.uci.endsWith('q'))
          .toList();
      if (queenPromo.length == 1) return queenPromo.first;
    }

    return null;
  }

  /// True if [input] is a prefix of at least one legal move's SAN or UCI.
  bool _hasMatchingPrefix(String input) {
    final stripped = _stripAnnotations(input);
    final lower = stripped.toLowerCase();
    final castlingNorm = _castlingNormalize(lower);
    return _legalMoves.any((e) =>
        _normalizeSan(e.san).startsWith(castlingNorm) ||
        _stripAnnotations(e.san).startsWith(stripped) ||
        e.uciStartsWith(lower));
  }

  static String _stripAnnotations(String s) =>
      s.replaceAll(RegExp(r'[+#?!x]'), '').trim();

  /// Lowercase + treat 0 as O for castling shorthand.
  static String _castlingNormalize(String lower) =>
      lower.replaceAll('0', 'o');

  static String _normalizeSan(String san) =>
      _castlingNormalize(_stripAnnotations(san).toLowerCase());

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = _error != null;
    final inputText = _controller.text.trim();

    return SizedBox(
      height: 36,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        enabled: widget.enabled,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.none,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9\-]')),
          LengthLimitingTextInputFormatter(7),
        ],
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: hasError
              ? theme.colorScheme.error
              : theme.colorScheme.onSurface.withValues(alpha: 0.8),
        ),
        decoration: InputDecoration(
          hintText: widget.enabled ? 'Type a move…' : '',
          hintStyle: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 8, right: 4),
            child: Icon(
              Icons.keyboard_alt_outlined,
              size: 16,
              color: widget.enabled
                  ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.15),
            ),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 28, minHeight: 0),
          suffixIcon: inputText.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 14),
                  onPressed: () {
                    _controller.clear();
                    setState(() => _error = null);
                  },
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                )
              : null,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          isDense: true,
          filled: false,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(
              color: hasError
                  ? theme.colorScheme.error.withValues(alpha: 0.4)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(
              color: hasError
                  ? theme.colorScheme.error.withValues(alpha: 0.4)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(
              color: hasError
                  ? theme.colorScheme.error.withValues(alpha: 0.6)
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.1),
            ),
          ),
        ),
        onChanged: _onChanged,
        onSubmitted: (_) {
          _focusNode.requestFocus();
        },
      ),
    );
  }
}

/// Representation of a single legal move with SAN and UCI forms.
class LegalMoveEntry {
  final String san;

  /// Primary UCI plus any aliases (e.g. castling king→rook + king→dest).
  final List<String> uciAliases;
  final String from;
  final String to;
  final String fenBefore;
  final String fenAfter;

  String get uci => uciAliases.first;

  const LegalMoveEntry({
    required this.san,
    required this.uciAliases,
    required this.from,
    required this.to,
    required this.fenBefore,
    required this.fenAfter,
  });

  bool matchesUci(String lower) =>
      uciAliases.any((a) => a.toLowerCase() == lower);

  bool uciStartsWith(String lower) =>
      uciAliases.any((a) => a.toLowerCase().startsWith(lower));
}
