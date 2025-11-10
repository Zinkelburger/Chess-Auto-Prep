/// Interactive PGN editor widget for repertoire building
/// Allows real-time editing, move addition, variation management, and commenting
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:dartchess/dartchess.dart';
import 'dart:io' as io;

class PgnMove {
  final String san;
  final String? comment;
  final List<PgnMove> variations;
  final bool isMainline;

  PgnMove({
    required this.san,
    this.comment,
    List<PgnMove>? variations,
    this.isMainline = true,
  }) : variations = variations ?? [];

  PgnMove copyWith({
    String? san,
    String? comment,
    List<PgnMove>? variations,
    bool? isMainline,
  }) {
    return PgnMove(
      san: san ?? this.san,
      comment: comment ?? this.comment,
      variations: variations ?? this.variations,
      isMainline: isMainline ?? this.isMainline,
    );
  }

  void addVariation(PgnMove variation) {
    variations.add(variation.copyWith(isMainline: false));
  }
}

class PgnEditorController {
  _InteractivePgnEditorState? _state;

  void _bindState(_InteractivePgnEditorState state) {
    _state = state;
  }

  void addMove(String san) {
    print('PgnEditorController.addMove called with: $san'); // Debug
    _state?.addMove(san);
  }

  void syncToPosition(String fen) {
    _state?._syncToPosition(fen);
  }

  void clearLine() {
    _state?._clearLine();
  }
}

class InteractivePgnEditor extends StatefulWidget {
  final Function(Position)? onPositionChanged;
  final String? initialPgn;
  final Function(String)? onPgnChanged;
  final PgnEditorController? controller;

  const InteractivePgnEditor({
    super.key,
    this.onPositionChanged,
    this.initialPgn,
    this.onPgnChanged,
    this.controller,
  });

  @override
  State<InteractivePgnEditor> createState() => _InteractivePgnEditorState();
}

class _InteractivePgnEditorState extends State<InteractivePgnEditor> {
  // Game state
  Position _currentPosition = Chess.initial;
  List<PgnMove> _moves = [];
  int _currentMoveIndex = -1; // -1 means starting position

  // UI state
  int? _selectedMoveIndex;
  final TextEditingController _commentController = TextEditingController();
  bool _showingContextMenu = false;
  Offset _contextMenuPosition = Offset.zero;
  int? _contextMenuMoveIndex;

  // Workflow state
  String _workingPgn = '';
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();

    // Bind controller
    widget.controller?._bindState(this);

    if (widget.initialPgn != null && widget.initialPgn!.isNotEmpty) {
      _loadInitialPgn(widget.initialPgn!);
    }
    _updatePosition();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  void _loadInitialPgn(String pgn) {
    try {
      // Parse existing PGN and convert to our format
      final game = PgnGame.parsePgn(pgn);
      final mainlineNodes = game.moves.mainline().toList();

      _moves.clear();
      for (final node in mainlineNodes) {
        _moves.add(PgnMove(
          san: node.san,
          comment: node.comments?.join(' '),
        ));
      }
    } catch (e) {
      // If parsing fails, start with empty moves
      _moves.clear();
    }
  }

  /// Called when user makes a move on the chess board
  void addMove(String san) {
    print('InteractivePgnEditor.addMove called with: $san'); // Debug
    print('Current position FEN: ${_currentPosition.fen}'); // Debug
    print('Current move index: $_currentMoveIndex'); // Debug

    try {
      // Validate the move against current position
      final move = _currentPosition.parseSan(san);
      if (move == null) {
        print('Move $san is invalid for current position'); // Debug
        return;
      }

      print('Move $san is valid, adding to PGN'); // Debug

      setState(() {
        final newMove = PgnMove(san: san);

        if (_currentMoveIndex == _moves.length - 1) {
          // Extending the main line
          _moves.add(newMove);
          _currentMoveIndex++;
          print('Added move to end of line'); // Debug
        } else if (_currentMoveIndex < _moves.length - 1) {
          // Check if this move differs from the existing continuation
          final existingNextMove = _moves[_currentMoveIndex + 1];

          if (existingNextMove.san == san) {
            // Same move, just advance
            _currentMoveIndex++;
            print('Move matches existing line, advanced'); // Debug
          } else {
            // Different move - create a variation
            // For now, add as alternative mainline (simplified)
            _moves.insert(_currentMoveIndex + 1, newMove);
            _currentMoveIndex++;
            print('Created variation: $san vs ${existingNextMove.san}'); // Debug

            // In a full implementation, this would create a proper variation tree
            // existingNextMove.addVariation(newMove);
          }
        } else {
          // Adding to an empty line or extending
          _moves.add(newMove);
          _currentMoveIndex++;
          print('Added move to line'); // Debug
        }

        _hasUnsavedChanges = true;
        _updatePosition();
        _generateWorkingPgn();

        print('PGN now has ${_moves.length} moves'); // Debug
        print('Working PGN: $_workingPgn'); // Debug
      });
    } catch (e) {
      print('Error in addMove: $e'); // Debug
    }
  }

  void _updatePosition() {
    // Rebuild position up to current move index
    Position position = Chess.initial;

    for (int i = 0; i <= _currentMoveIndex && i < _moves.length; i++) {
      final move = position.parseSan(_moves[i].san);
      if (move != null) {
        position = position.play(move);
      } else {
        break;
      }
    }

    _currentPosition = position;
    widget.onPositionChanged?.call(_currentPosition);
  }

  void _syncToPosition(String fen) {
    // Sync the PGN editor's internal position to match the given FEN
    // This is used when the external chess board position changes
    try {
      final targetPosition = Chess.fromSetup(Setup.parseFen(fen));

      // Find which move index corresponds to this position
      Position checkPosition = Chess.initial;
      int targetIndex = -1;

      for (int i = 0; i < _moves.length; i++) {
        final move = checkPosition.parseSan(_moves[i].san);
        if (move != null) {
          checkPosition = checkPosition.play(move);
          // Compare FEN positions (normalize by removing move counters if needed)
          if (_normalizeFen(checkPosition.fen) == _normalizeFen(fen)) {
            targetIndex = i;
            break;
          }
        }
      }

      if (targetIndex != _currentMoveIndex) {
        setState(() {
          _currentMoveIndex = targetIndex;
          _currentPosition = targetPosition;
        });
        print('Synced PGN editor to move index: $targetIndex'); // Debug
      }
    } catch (e) {
      print('Error syncing PGN editor position: $e'); // Debug
    }
  }

  /// Normalize FEN by removing move counters for comparison
  String _normalizeFen(String fen) {
    final parts = fen.split(' ');
    if (parts.length >= 4) {
      // Return just the position, turn, castling, and en passant parts
      return '${parts[0]} ${parts[1]} ${parts[2]} ${parts[3]}';
    }
    return fen;
  }

  void _generateWorkingPgn() {
    // Generate PGN string from current moves
    final buffer = StringBuffer();

    var moveNumber = 1;
    var isWhiteTurn = true;

    for (int i = 0; i < _moves.length; i++) {
      final move = _moves[i];

      // Add move number for white's moves
      if (isWhiteTurn) {
        buffer.write('$moveNumber. ');
      }

      // Add the move
      buffer.write('${move.san} ');

      // Add comment if exists
      if (move.comment != null && move.comment!.isNotEmpty) {
        buffer.write('{${move.comment}} ');
      }

      // Update counters
      if (!isWhiteTurn) {
        moveNumber++;
      }
      isWhiteTurn = !isWhiteTurn;
    }

    _workingPgn = buffer.toString().trim();
    widget.onPgnChanged?.call(_workingPgn);
  }

  void _goToMove(int moveIndex) {
    setState(() {
      _currentMoveIndex = moveIndex;
      _selectedMoveIndex = moveIndex;
      _updatePosition();

      // Update comment controller with selected move's comment
      if (moveIndex >= 0 && moveIndex < _moves.length) {
        _commentController.text = _moves[moveIndex].comment ?? '';
      } else {
        _commentController.text = '';
      }
    });
  }

  void _showContextMenu(int moveIndex, Offset globalPosition) {
    setState(() {
      _contextMenuMoveIndex = moveIndex;
      _contextMenuPosition = globalPosition;
      _showingContextMenu = true;
    });
  }

  void _hideContextMenu() {
    setState(() {
      _showingContextMenu = false;
      _contextMenuMoveIndex = null;
    });
  }

  void _addComment() {
    _hideContextMenu();
    // Focus on comment field - the live editing will handle the rest
    FocusScope.of(context).requestFocus();
  }

  void _deleteMove() {
    if (_contextMenuMoveIndex == null) return;

    setState(() {
      _moves.removeAt(_contextMenuMoveIndex!);
      _hasUnsavedChanges = true;

      // Adjust current move index if necessary
      if (_currentMoveIndex >= _contextMenuMoveIndex!) {
        _currentMoveIndex = (_contextMenuMoveIndex! - 1).clamp(-1, _moves.length - 1);
      }

      _hideContextMenu();
      _updatePosition();
      _generateWorkingPgn();
    });
  }

  void _promoteVariation() {
    // Future: Move variation to become the mainline, demoting current mainline to variation
    _hideContextMenu();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Promote Variation: Will make this variation the new mainline'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _setMainline() {
    // Future: Make this move the main continuation, creating variations for alternative moves
    _hideContextMenu();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Set Mainline: Will establish this as the primary continuation'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _updateSelectedMoveComment(String comment) {
    if (_selectedMoveIndex == null || _selectedMoveIndex! < 0 || _selectedMoveIndex! >= _moves.length) {
      return;
    }

    setState(() {
      _moves[_selectedMoveIndex!] = _moves[_selectedMoveIndex!].copyWith(comment: comment);
      _hasUnsavedChanges = true;
      _generateWorkingPgn();
    });
  }

  Future<void> _addToRepertoire() async {
    if (_workingPgn.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No moves to add to repertoire')),
      );
      return;
    }

    // Show dialog to get repertoire name or select existing
    final result = await _showAddToRepertoireDialog();
    if (result == null) return;

    try {
      // Append to or create repertoire file
      await _saveToRepertoireFile(result, _workingPgn);

      setState(() {
        _hasUnsavedChanges = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added line to repertoire: $result')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving to repertoire: $e')),
        );
      }
    }
  }

  Future<String?> _showAddToRepertoireDialog() async {
    final controller = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add to Repertoire'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter repertoire name:'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Repertoire Name',
                hintText: 'e.g., "Sicilian Dragon"',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(context, name);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveToRepertoireFile(String repertoireName, String pgn) async {
    // Get repertoire directory
    final homeDir = io.Platform.environment['HOME'] ?? '/tmp';
    final repertoireDir = io.Directory('$homeDir/Documents/CodingProjects/Chess-Auto-Prep/repertoires');

    if (!await repertoireDir.exists()) {
      await repertoireDir.create(recursive: true);
    }

    final file = io.File('${repertoireDir.path}/$repertoireName.pgn');

    // Create PGN entry with headers
    final timestamp = DateTime.now().toIso8601String().split('T')[0];
    final entry = '''

[Event "$repertoireName Line"]
[Date "$timestamp"]
[White "Training"]
[Black "Me"]

$pgn
''';

    // Append to file
    if (await file.exists()) {
      await file.writeAsString(await file.readAsString() + entry, mode: io.FileMode.write);
    } else {
      await file.writeAsString('// $repertoireName Repertoire$entry');
    }
  }

  void _clearLine() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Line'),
        content: const Text('Clear current line and start over? Unsaved changes will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _moves.clear();
                _currentMoveIndex = -1;
                _selectedMoveIndex = null;
                _workingPgn = '';
                _hasUnsavedChanges = false;
                _commentController.clear();
                _updatePosition();
              });
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            // PGN Display
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[700]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      children: [
                        const Text(
                          'PGN Editor',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const Spacer(),
                        if (_hasUnsavedChanges)
                          const Icon(Icons.circle, size: 8, color: Colors.orange),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Moves display
                    Expanded(
                      child: SingleChildScrollView(
                        child: _buildMovesDisplay(),
                      ),
                    ),

                    // Comment editing
                    const Divider(),
                    Row(
                      children: [
                        const Text('Comment: ', style: TextStyle(fontWeight: FontWeight.bold)),
                        Expanded(
                          child: TextField(
                            controller: _commentController,
                            decoration: const InputDecoration(
                              hintText: 'Add comment to selected move...',
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            style: const TextStyle(fontSize: 12),
                            onChanged: _updateSelectedMoveComment,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Workflow buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _moves.isNotEmpty ? _addToRepertoire : null,
                    icon: const Icon(Icons.add_box),
                    label: const Text('Add to Repertoire'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[700],
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _moves.isNotEmpty ? _clearLine : null,
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear Line'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[700],
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),

        // Context menu overlay
        if (_showingContextMenu)
          _buildContextMenu(),
      ],
    );
  }

  Widget _buildMovesDisplay() {
    if (_moves.isEmpty) {
      return const Text(
        'Make moves on the board to start building your line...',
        style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
      );
    }

    final spans = <InlineSpan>[];
    var moveNumber = 1;
    var isWhiteTurn = true;

    for (int i = 0; i < _moves.length; i++) {
      final move = _moves[i];
      final isSelected = i == _selectedMoveIndex;
      final isCurrent = i == _currentMoveIndex;

      // Add move number for white's moves
      if (isWhiteTurn) {
        spans.add(TextSpan(
          text: '$moveNumber. ',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      }

      // Add the move with appropriate styling
      Color moveColor;
      Color? backgroundColor;

      if (isSelected) {
        moveColor = Colors.white;
        backgroundColor = Colors.blue[700];
      } else if (isCurrent) {
        moveColor = Colors.orange;
        backgroundColor = Colors.grey[800];
      } else {
        moveColor = Colors.blue[300]!;
      }

      spans.add(TextSpan(
        text: move.san,
        style: TextStyle(
          color: moveColor,
          backgroundColor: backgroundColor,
          fontWeight: isSelected || isCurrent ? FontWeight.bold : FontWeight.normal,
          decoration: TextDecoration.underline,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => _goToMove(i),
      ));

      spans.add(const TextSpan(text: ' '));

      // Add comment if exists
      if (move.comment != null && move.comment!.isNotEmpty) {
        spans.add(TextSpan(
          text: '{${move.comment}} ',
          style: const TextStyle(
            color: Colors.green,
            fontStyle: FontStyle.italic,
          ),
        ));
      }

      // Update for next iteration
      if (!isWhiteTurn) {
        moveNumber++;
      }
      isWhiteTurn = !isWhiteTurn;
    }

    return GestureDetector(
      onSecondaryTapDown: (details) {
        // Capture position for context menu
        _contextMenuPosition = details.globalPosition;

        // Find which move was right-clicked (simplified - would need more precise hit testing)
        if (_selectedMoveIndex != null) {
          _showContextMenu(_selectedMoveIndex!, details.globalPosition);
        }
      },
      child: RichText(
        text: TextSpan(
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 14,
            color: Colors.white,
          ),
          children: spans,
        ),
      ),
    );
  }

  Widget _buildContextMenu() {
    return Positioned(
      left: _contextMenuPosition.dx + 10,
      top: _contextMenuPosition.dy + 10,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey[800],
        child: Container(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildContextMenuItem(
                icon: Icons.comment,
                text: 'Add Comment',
                onTap: _addComment,
              ),
              _buildContextMenuItem(
                icon: Icons.arrow_upward,
                text: 'Promote Variation',
                onTap: _promoteVariation,
              ),
              _buildContextMenuItem(
                icon: Icons.trending_up,
                text: 'Set Mainline',
                onTap: _setMainline,
              ),
              _buildContextMenuItem(
                icon: Icons.delete,
                text: 'Delete',
                onTap: _deleteMove,
                color: Colors.red,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContextMenuItem({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
    Color? color,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color ?? Colors.white),
            const SizedBox(width: 8),
            Text(
              text,
              style: TextStyle(color: color ?? Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}