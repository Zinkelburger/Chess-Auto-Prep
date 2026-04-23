/// PGN viewer with an optional inline engine bar.
///
/// Drop-in replacement for [PgnViewerWidget] that adds a compact Stockfish
/// MultiPV display above the PGN.  The engine bar tracks the PGN viewer's
/// current position automatically.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'engine/inline_engine_bar.dart';
import 'pgn_viewer_widget.dart';

class PgnWithEngine extends StatefulWidget {
  // All PgnViewerWidget props (passthrough)
  final String? gameId;
  final String? pgnText;
  final int? moveNumber;
  final bool? isWhiteToPlay;
  final Function(Position)? onPositionChanged;
  final PgnViewerController? controller;
  final String? initialFen;
  final bool showStartEndButtons;

  const PgnWithEngine({
    super.key,
    this.gameId,
    this.pgnText,
    this.moveNumber,
    this.isWhiteToPlay,
    this.onPositionChanged,
    this.controller,
    this.initialFen,
    this.showStartEndButtons = true,
  });

  @override
  State<PgnWithEngine> createState() => _PgnWithEngineState();
}

class _PgnWithEngineState extends State<PgnWithEngine> {
  String _currentFen = Chess.initial.fen;

  void _onPositionChanged(Position position) {
    setState(() => _currentFen = position.fen);
    widget.onPositionChanged?.call(position);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InlineEngineBar(fen: _currentFen),
        const Divider(height: 1),
        Expanded(
          child: PgnViewerWidget(
            key: widget.key != null
                ? ValueKey('pgn_inner_${widget.key}')
                : null,
            gameId: widget.gameId,
            pgnText: widget.pgnText,
            moveNumber: widget.moveNumber,
            isWhiteToPlay: widget.isWhiteToPlay,
            controller: widget.controller,
            initialFen: widget.initialFen,
            showStartEndButtons: widget.showStartEndButtons,
            onPositionChanged: _onPositionChanged,
          ),
        ),
      ],
    );
  }
}
