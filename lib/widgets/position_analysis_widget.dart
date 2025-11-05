/// Position analysis widget - Flutter port of Python's PositionAnalysisMode
/// Three-panel layout: FEN list (left), chess board (center), tabs (right)

import 'package:flutter/material.dart';
import 'package:chess/chess.dart' as chess;

import '../models/position_analysis.dart';
import '../widgets/fen_list_widget.dart';
import '../widgets/games_list_widget.dart';
import 'chess_board_widget.dart';
import 'pgn_viewer_widget.dart';

class PositionAnalysisWidget extends StatefulWidget {
  final PositionAnalysis? analysis;
  final bool? playerIsWhite; // Player's color for consistent board orientation
  final Function()? onAnalyze;

  const PositionAnalysisWidget({
    super.key,
    this.analysis,
    this.playerIsWhite,
    this.onAnalyze,
  });

  @override
  State<PositionAnalysisWidget> createState() => _PositionAnalysisWidgetState();
}

class _PositionAnalysisWidgetState extends State<PositionAnalysisWidget>
    with SingleTickerProviderStateMixin {
  chess.Chess? _currentBoard;
  String? _currentFen;
  GameInfo? _selectedGame;
  late TabController _tabController;
  List<GameInfo> _currentGames = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.analysis == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.analytics, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'No positions analyzed',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            const Text(
              'Click "Analyze Positions" to begin',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            if (widget.onAnalyze != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: widget.onAnalyze,
                icon: const Icon(Icons.analytics),
                label: const Text('Analyze Positions'),
              ),
            ],
          ],
        ),
      );
    }

    return Row(
      children: [
        // Left panel - FEN list
        SizedBox(
          width: 300,
          child: FenListWidget(
            analysis: widget.analysis!,
            onFenSelected: _onFenSelected,
          ),
        ),

        // Divider
        Container(
          width: 1,
          color: Colors.grey[700],
        ),

        // Center panel - Chess board
        Expanded(
          flex: 3,
          child: Center(
            child: _currentBoard != null
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: AspectRatio(
                      aspectRatio: 1.0,
                      child: ChessBoardWidget(
                        game: _currentBoard!,
                        // Keep board oriented from player's perspective
                        flipped: widget.playerIsWhite != null
                            ? !widget.playerIsWhite!
                            : false,
                        onMove: null, // No moves allowed in analysis view
                      ),
                    ),
                  )
                : const Text(
                    'Select a position to view',
                    style: TextStyle(color: Colors.grey),
                  ),
          ),
        ),

        // Divider
        Container(
          width: 1,
          color: Colors.grey[700],
        ),

        // Right panel - Tabs (PGN viewer and Games list)
        SizedBox(
          width: 350,
          child: Column(
            children: [
              TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: 'Games'),
                  Tab(text: 'PGN'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    // Games tab
                    GamesListWidget(
                      games: _currentGames,
                      currentFen: _currentFen,
                      onGameSelected: _onGameSelected,
                    ),

                    // PGN tab
                    _selectedGame != null && _selectedGame!.pgnText != null
                        ? PgnViewerWidget(
                            pgnText: _selectedGame!.pgnText!,
                            onPositionChanged: (position) {
                              // Update chess board when clicking moves
                              try {
                                setState(() {
                                  _currentBoard = chess.Chess.fromFEN(position.fen);
                                });
                              } catch (e) {
                                // Handle error
                              }
                            },
                          )
                        : const Center(
                            child: Text(
                              'Select a game to view PGN',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _onFenSelected(String fen) {
    setState(() {
      _currentFen = fen;
      try {
        // FEN might be shortened (without move counters), add them if missing
        String fullFen = fen;
        final parts = fen.split(' ');
        if (parts.length == 4) {
          // Add default halfmove and fullmove counters
          fullFen = '$fen 0 1';
        }
        _currentBoard = chess.Chess.fromFEN(fullFen);
      } catch (e) {
        _currentBoard = null;
      }
      _selectedGame = null;

      // Update games list
      if (widget.analysis != null) {
        _currentGames = widget.analysis!.getGamesForFen(fen);
      }
    });

    // Switch to games tab when new position selected
    _tabController.animateTo(0);
  }

  void _onGameSelected(GameInfo game) {
    setState(() {
      _selectedGame = game;
    });

    // Switch to PGN tab when game selected
    _tabController.animateTo(1);
  }
}