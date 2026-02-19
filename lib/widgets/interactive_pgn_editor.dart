/// Interactive PGN editor widget for repertoire building
/// Allows real-time editing, move addition, variation management, and commenting
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';

// Simple counter for unique move IDs
int _pgnMoveIdCounter = 0;

class PgnMove {
  final String san;
  final String? comment;
  final List<PgnMove> children; // First child is mainline, subsequent are variations
  
  // Helper to identify this move instance in the tree
  final int id; 

  PgnMove({
    required this.san,
    this.comment,
    List<PgnMove>? children,
    int? id,
  }) : children = children ?? [],
       id = id ?? _pgnMoveIdCounter++;

  PgnMove copyWith({
    String? san,
    String? comment,
    List<PgnMove>? children,
  }) {
    return PgnMove(
      san: san ?? this.san,
      comment: comment ?? this.comment,
      children: children ?? this.children,
      id: this.id,
    );
  }
}

class PgnEditorController {
  _InteractivePgnEditorState? _state;

  void _bindState(_InteractivePgnEditorState state) {
    _state = state;
  }

  void _unbindState() {
    _state = null;
  }

  void addMove(String san) {
    _state?.addMove(san);
  }

  void syncToPosition(String fen) {
    _state?._syncToPosition(fen);
  }

  /// Sync editor to a specific move index with given move list
  /// Note: This legacy method flattens the tree or assumes a linear history
  void syncToMoveHistory(List<String> moves, int moveIndex) {
    _state?._syncToMoveHistory(moves, moveIndex);
  }

  void clearLine() {
    _state?._clearLine();
  }

  void goBack() {
    _state?._goBack();
  }

  void goForward() {
    _state?._goForward();
  }

  /// Get current move index in the flattened current line
  int get currentMoveIndex => _state?._currentMoveIndex ?? -1;

  /// Get current moves list (flattened current line)
  List<String> get moves => _state?._currentLineSan ?? [];
}

class InteractivePgnEditor extends StatefulWidget {
  final Function(Position)? onPositionChanged;
  /// Called when move state changes - reports current move index and full move list
  final Function(int moveIndex, List<String> moves)? onMoveStateChanged;
  final String? initialPgn;
  final Function(String)? onPgnChanged;
  final PgnEditorController? controller;
  final String? currentRepertoireName;
  final String? repertoireColor; // "White" or "Black"
  final List<String> moveHistory;
  final int currentMoveIndex;
  /// Starting FEN if different from standard position (for custom positions)
  final String? startingFen;
  /// Called after a line is successfully saved to the repertoire file.
  /// Provides the moves list, title, and full PGN so the caller can
  /// append to the in-memory tree without a full reload.
  final Function(List<String> moves, String title, String pgn)? onLineSaved;

  const InteractivePgnEditor({
    super.key,
    this.onPositionChanged,
    this.onMoveStateChanged,
    this.initialPgn,
    this.onPgnChanged,
    this.controller,
    this.currentRepertoireName,
    this.repertoireColor,
    this.moveHistory = const [],
    this.currentMoveIndex = -1,
    this.startingFen,
    this.onLineSaved,
  });

  @override
  State<InteractivePgnEditor> createState() => _InteractivePgnEditorState();
}

class _InteractivePgnEditorState extends State<InteractivePgnEditor> {
  // Game state
  Position _currentPosition = Chess.initial;
  List<PgnMove> _roots = []; // The root moves (usually 1, e.g. 1. e4)
  List<PgnMove> _currentPath = []; // The path of moves to the current position
  
  // Derived state for compatibility/display
  List<String> get _currentLineSan => _currentPath.map((m) => m.san).toList();
  int get _currentMoveIndex => _currentPath.isEmpty ? -1 : _currentPath.length - 1;

  // UI state
  int? _selectedMoveId;
  final TextEditingController _commentController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  bool _showingContextMenu = false;
  Offset _contextMenuPosition = Offset.zero;
  int? _contextMenuMoveId;

  // Workflow state
  String _workingPgn = '';
  bool _hasUnsavedChanges = false;
  
  // Flag to prevent callback loops when syncing from external source (controller)
  bool _isSyncingFromExternal = false;

  @override
  void initState() {
    super.initState();

    // Bind controller
    widget.controller?._bindState(this);

    if (widget.initialPgn != null && widget.initialPgn!.isNotEmpty) {
      _loadInitialPgn(widget.initialPgn!);
    }
    
    // Sync to initial move history if provided
    if (widget.moveHistory.isNotEmpty || widget.currentMoveIndex != -1) {
      _syncToMoveHistory(widget.moveHistory, widget.currentMoveIndex);
    } else {
      _updatePosition();
    }
  }

  @override
  void didUpdateWidget(InteractivePgnEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_listsEqual(widget.moveHistory, oldWidget.moveHistory) ||
        widget.currentMoveIndex != oldWidget.currentMoveIndex) {
      _syncToMoveHistory(widget.moveHistory, widget.currentMoveIndex);
    }
  }

  bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    widget.controller?._unbindState();
    _commentController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _loadInitialPgn(String pgn) {
    try {
      final game = PgnGame.parsePgn(pgn);
      // Convert dartchess PgnNode tree to our PgnMove tree
      final rootNodes = game.moves.children;
      _roots = _convertNodes(rootNodes);
      // Default path is empty (start position)
      _currentPath = [];

      // Pre-populate title from [Event] header (skip placeholders)
      final event = game.headers['Event'] ?? '';
      if (event.isNotEmpty &&
          event != '?' &&
          event != 'Repertoire Line' &&
          event != 'Edited Line') {
        _titleController.text = event;
      }
    } catch (e) {
      _roots = [];
      _currentPath = [];
    }
  }

  List<PgnMove> _convertNodes(List<PgnChildNode<PgnNodeData>> nodes) {
    final moves = <PgnMove>[];
    for (final node in nodes) {
      // Recursive conversion - dartchess uses node.data to access PgnNodeData
      moves.add(PgnMove(
        san: node.data.san,
        comment: node.data.comments?.join(' '),
        children: _convertNodes(node.children),
      ));
    }
    return moves;
  }

  /// Called when user makes a move on the chess board
  void addMove(String san) {
    final move = _currentPosition.parseSan(san);
    if (move == null) return;

    setState(() {
      final newMove = PgnMove(san: san);

      if (_currentPath.isEmpty) {
        // Adding at root level (move 1)
        _addToSiblingList(_roots, newMove);
      } else {
        // Adding to current leaf
        final parent = _currentPath.last;
        _addToSiblingList(parent.children, newMove);
      }
      
      // Advance path to include the new move
      if (_currentPath.isEmpty) {
        final added = _roots.firstWhere((m) => m.san == san);
        _currentPath = [added];
      } else {
        final parent = _currentPath.last;
        final added = parent.children.firstWhere((m) => m.san == san);
        _currentPath = List.from(_currentPath)..add(added);
      }

      _hasUnsavedChanges = true;
      _updatePosition();
      _generateWorkingPgn();
    });
  }

  void _addToSiblingList(List<PgnMove> siblings, PgnMove newMove) {
    // Check if move already exists
    for (final sibling in siblings) {
      if (sibling.san == newMove.san) {
        // Move exists, no need to add
        return;
      }
    }
    siblings.add(newMove);
  }

  void _updatePosition() {
    Position position;
    try {
      position = widget.startingFen != null
          ? Chess.fromSetup(Setup.parseFen(widget.startingFen!))
          : Chess.initial;
    } catch (_) {
      position = Chess.initial;
    }
    for (final moveNode in _currentPath) {
      final move = position.parseSan(moveNode.san);
      if (move == null) break;
      position = position.play(move);
    }
    _currentPosition = position;
    widget.onPositionChanged?.call(_currentPosition);
    _notifyMoveStateChanged();
  }

  void _notifyMoveStateChanged() {
    // Don't notify if we're syncing from external source (prevents loops)
    if (_isSyncingFromExternal) return;
    
    widget.onMoveStateChanged?.call(
      _currentMoveIndex,
      _currentLineSan,
    );
  }

  void _syncToPosition(String fen) {
    // No-op for now as tree navigation is complex
  }

  void _syncToMoveHistory(List<String> moves, int moveIndex) {
    if (!mounted) return;
    
    // Mark that we're syncing from external source to prevent callback loops
    _isSyncingFromExternal = true;
    
    setState(() {
      // Reset to root
      _currentPath = [];
      var currentSiblings = _roots;
      
      for (int i = 0; i < moves.length; i++) {
        final san = moves[i];
        // Find or create
        PgnMove? match;
        for (final m in currentSiblings) {
          if (m.san == san) {
            match = m;
            break;
          }
        }
        
        if (match == null) {
          match = PgnMove(san: san);
          currentSiblings.add(match);
        }
        
        _currentPath.add(match);
        currentSiblings = match.children;
      }
      
      // Now truncate path if moveIndex is less than full history
      if (moveIndex < _currentPath.length - 1) {
        if (moveIndex == -1) {
          _currentPath = [];
        } else {
          _currentPath = _currentPath.sublist(0, moveIndex + 1);
        }
      }
      
      _updatePositionWithoutCallback();
      _generateWorkingPgn();
    });
    
    _isSyncingFromExternal = false;
  }
  
  /// Update position without triggering external callbacks (used during sync)
  void _updatePositionWithoutCallback() {
    Position position;
    try {
      position = widget.startingFen != null
          ? Chess.fromSetup(Setup.parseFen(widget.startingFen!))
          : Chess.initial;
    } catch (_) {
      position = Chess.initial;
    }
    for (final moveNode in _currentPath) {
      final move = position.parseSan(moveNode.san);
      if (move == null) break;
      position = position.play(move);
    }
    _currentPosition = position;
  }

  void _generateWorkingPgn() {
    final buffer = StringBuffer();
    
    // Add FEN header if we have a custom starting position
    if (widget.startingFen != null) {
      buffer.writeln('[FEN "${widget.startingFen}"]');
      buffer.writeln('[SetUp "1"]');
      buffer.writeln();
    }
    
    if (_roots.isNotEmpty) {
      _writePgnTree(buffer, _roots);
    }
    _workingPgn = buffer.toString().trim();
    widget.onPgnChanged?.call(_workingPgn);
  }

  void _writePgnTree(StringBuffer buffer, List<PgnMove> siblings) {
    if (siblings.isEmpty) return;
    
    // Determine starting move number and side to move from FEN
    int startMoveNumber = 1;
    bool startIsWhite = true;
    
    if (widget.startingFen != null) {
      final fenParts = widget.startingFen!.split(' ');
      if (fenParts.length >= 2) {
        startIsWhite = fenParts[1] == 'w';
      }
      if (fenParts.length >= 6) {
        startMoveNumber = int.tryParse(fenParts[5]) ?? 1;
      }
    }
    
    _writeNodes(buffer, siblings, startMoveNumber, startIsWhite, isFirstMove: true);
  }

  void _writeNodes(StringBuffer buffer, List<PgnMove> siblings, int moveNumber, bool isWhite, {bool isFirstMove = false}) {
    if (siblings.isEmpty) return;

    final main = siblings[0];
    
    // Write main move - move number for White, or "X..." for Black on first move
    if (isWhite) {
      buffer.write('$moveNumber. ');
    } else if (isFirstMove) {
      buffer.write('$moveNumber... ');
    }
    
    buffer.write('${main.san} ');
    if (main.comment != null && main.comment!.isNotEmpty) {
      buffer.write('{${main.comment}} ');
    }

    // Write variations (siblings 1..n)
    for (int i = 1; i < siblings.length; i++) {
      buffer.write('(');
      // Variation starts at same move number and color
      if (isWhite) {
        buffer.write('$moveNumber. ');
      } else {
        buffer.write('$moveNumber... ');
      }
      
      final variant = siblings[i];
      buffer.write('${variant.san} ');
      if (variant.comment != null && variant.comment!.isNotEmpty) {
        buffer.write('{${variant.comment}} ');
      }
      
      // Continue variation line
      _writeNodes(buffer, variant.children, isWhite ? moveNumber : moveNumber + 1, !isWhite);
      
      buffer.write(') ');
    }

    // Continue main line
    _writeNodes(buffer, main.children, isWhite ? moveNumber : moveNumber + 1, !isWhite);
  }

  void _goToMove(int moveId) {
    final path = <PgnMove>[];
    if (_findPathRecursive(_roots, moveId, path)) {
      setState(() {
        _currentPath = path;
        _selectedMoveId = moveId;
        _updatePosition();
        
        // Update comment
        final move = path.last;
        _commentController.text = move.comment ?? '';
      });
    }
  }
  
  bool _findPathRecursive(List<PgnMove> nodes, int targetId, List<PgnMove> currentPath) {
    for (final node in nodes) {
      currentPath.add(node);
      if (node.id == targetId) {
        return true;
      }
      if (_findPathRecursive(node.children, targetId, currentPath)) {
        return true;
      }
      currentPath.removeLast();
    }
    return false;
  }

  void _goBack() {
    if (_currentPath.isNotEmpty) {
      setState(() {
        _currentPath.removeLast();
        if (_currentPath.isNotEmpty) {
          _selectedMoveId = _currentPath.last.id;
          _commentController.text = _currentPath.last.comment ?? '';
        } else {
          _selectedMoveId = null;
          _commentController.text = '';
        }
        _updatePosition();
      });
    }
  }

  void _goForward() {
    if (_currentPath.isEmpty) {
      if (_roots.isNotEmpty) {
        _goToMove(_roots[0].id);
      }
    } else {
      final last = _currentPath.last;
      if (last.children.isNotEmpty) {
        _goToMove(last.children[0].id);
      }
    }
  }

  void _showContextMenu(int moveId, Offset globalPosition) {
    setState(() {
      _contextMenuMoveId = moveId;
      _contextMenuPosition = globalPosition;
      _showingContextMenu = true;
    });
  }

  void _hideContextMenu() {
    setState(() {
      _showingContextMenu = false;
      _contextMenuMoveId = null;
    });
  }
  
  void _addComment() {
    _hideContextMenu();
    FocusScope.of(context).requestFocus();
  }

  void _deleteFromHere() {
    if (_contextMenuMoveId == null) return;
    
    final path = <PgnMove>[];
    if (_findPathRecursive(_roots, _contextMenuMoveId!, path)) {
      setState(() {
        if (path.length == 1) {
          _roots.remove(path.last);
        } else {
          final parent = path[path.length - 2];
          parent.children.remove(path.last);
        }
        
        final index = _currentPath.indexOf(path.last);
        if (index != -1) {
          _currentPath = _currentPath.sublist(0, index);
          _updatePosition();
        }
        
        _hasUnsavedChanges = true;
        _hideContextMenu();
        _generateWorkingPgn();
      });
    }
  }
  
  void _copyPgnFromHere() {
    if (_contextMenuMoveId == null) return;
    
    final path = <PgnMove>[];
    if (_findPathRecursive(_roots, _contextMenuMoveId!, path)) {
      final buffer = StringBuffer();
      
      // Determine starting move number and side from FEN
      int startMoveNumber = 1;
      bool startIsWhite = true;
      
      if (widget.startingFen != null) {
        final fenParts = widget.startingFen!.split(' ');
        if (fenParts.length >= 2) {
          startIsWhite = fenParts[1] == 'w';
        }
        if (fenParts.length >= 6) {
          startMoveNumber = int.tryParse(fenParts[5]) ?? 1;
        }
      }
      
      // Calculate current move number based on path position
      int moveNumber = startMoveNumber;
      bool isWhite = startIsWhite;
      for (int i = 0; i < path.length - 1; i++) {
        if (isWhite) {
          isWhite = false;
        } else {
          isWhite = true;
          moveNumber++;
        }
      }
      
      if (!isWhite) {
        buffer.write('$moveNumber... ');
      } else {
        buffer.write('$moveNumber. ');
      }
      
      _writeNodes(buffer, [path.last], moveNumber, isWhite);
      
      Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PGN copied to clipboard')),
      );
    }
    _hideContextMenu();
  }

  void _promoteVariation() {
    if (_contextMenuMoveId == null) return;

    final path = <PgnMove>[];
    if (_findPathRecursive(_roots, _contextMenuMoveId!, path)) {
      final target = path.last;
      
      setState(() {
        if (path.length == 1) {
          if (_roots.indexOf(target) > 0) {
            _roots.remove(target);
            _roots.insert(0, target);
            _hasUnsavedChanges = true;
            _generateWorkingPgn();
          }
        } else {
          final parent = path[path.length - 2];
          if (parent.children.indexOf(target) > 0) {
            parent.children.remove(target);
            parent.children.insert(0, target);
            _hasUnsavedChanges = true;
            _generateWorkingPgn();
          }
        }
      });
    }
    _hideContextMenu();
  }

  void _updateSelectedMoveComment(String comment) {
    if (_selectedMoveId == null) return;
    
    final path = <PgnMove>[];
    if (_findPathRecursive(_roots, _selectedMoveId!, path)) {
      setState(() {
        final target = path.last;
        final newMove = target.copyWith(comment: comment);
        
        if (path.length == 1) {
           final idx = _roots.indexOf(target);
           if (idx != -1) _roots[idx] = newMove;
        } else {
           final parent = path[path.length - 2];
           final idx = parent.children.indexOf(target);
           if (idx != -1) parent.children[idx] = newMove;
        }
        
        final pathIdx = _currentPath.indexOf(target);
        if (pathIdx != -1) {
           _currentPath[pathIdx] = newMove;
        }
        
        _hasUnsavedChanges = true;
        _generateWorkingPgn();
      });
    }
  }
  
  Future<void> _addToRepertoire() async {
     if (_workingPgn.isEmpty) return;
     String? repertoireName = widget.currentRepertoireName;
    if (repertoireName == null || repertoireName.isEmpty) {
      repertoireName = await _showAddToRepertoireDialog();
      if (repertoireName == null) return;
    }

    try {
      await _saveToRepertoireFile(repertoireName, _workingPgn);
      setState(() {
        _hasUnsavedChanges = false;
      });

      // Notify parent to append to in-memory tree
      final moves = _currentLineSan;
      final title = _titleController.text.trim();
      widget.onLineSaved?.call(moves, title, _workingPgn);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Line added to repertoire')),
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
        content: TextField(controller: controller),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveToRepertoireFile(String repertoireName, String pgn) async {
    // Append to repertoire file via StorageService
    // Note: This logic previously used dart:io append mode.
    // StorageService read/write implies full overwrite.
    // So we read, append, write.
    
    // Repertoire files live in the repertoires/ subdirectory
    final filename = 'repertoires/$repertoireName.pgn';
    String currentContent = await StorageFactory.instance.readRepertoirePgn(filename) ?? '';
    
    // Use user-provided title, falling back to "Repertoire Line"
    final title = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
        : 'Repertoire Line';
    
    final entry = '\n[Event "$title"]\n[Date "${DateTime.now().toIso8601String()}"]\n\n$pgn\n';
    
    await StorageFactory.instance.saveRepertoirePgn(filename, currentContent + entry);
  }

  void _clearLine() {
      setState(() {
        _roots.clear();
        _currentPath.clear();
        _selectedMoveId = null;
        _workingPgn = '';
        _updatePosition();
      });
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
                    // Line title
                    TextField(
                      controller: _titleController,
                      decoration: InputDecoration(
                        hintText: 'Title',
                        hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 2),
                      ),
                      style: TextStyle(fontSize: 12, color: Colors.grey[300]),
                      onChanged: (_) {
                        setState(() {
                          _hasUnsavedChanges = true;
                        });
                      },
                    ),
                    Divider(height: 1, color: Colors.grey[800]),
                    const SizedBox(height: 4),
                    // Moves display
                    Expanded(
                      child: SingleChildScrollView(
                        child: _buildMovesDisplay(),
                      ),
                    ),
                    // Comment for selected move
                    Divider(height: 1, color: Colors.grey[800]),
                    TextField(
                      controller: _commentController,
                      decoration: InputDecoration(
                        hintText: 'Add comment',
                        hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      ),
                      style: TextStyle(fontSize: 12, color: Colors.grey[300]),
                      onChanged: _updateSelectedMoveComment,
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
                    onPressed: _roots.isNotEmpty ? _addToRepertoire : null,
                    icon: const Icon(Icons.add_box),
                    label: const Text('Add to Repertoire'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green[700]),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _roots.isNotEmpty ? _clearLine : null,
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear Line'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700]),
                  ),
                ),
              ],
            ),
          ],
        ),
        if (_showingContextMenu) _buildContextMenu(),
      ],
    );
  }

  Widget _buildMovesDisplay() {
    if (_roots.isEmpty) {
      return const Text(
        'Make moves on the board to start building your line...',
        style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
      );
    }
    
    // Determine starting move number and side to move from FEN
    int startMoveNumber = 1;
    bool startIsWhite = true;
    
    if (widget.startingFen != null) {
      final fenParts = widget.startingFen!.split(' ');
      if (fenParts.length >= 2) {
        startIsWhite = fenParts[1] == 'w';
      }
      if (fenParts.length >= 6) {
        startMoveNumber = int.tryParse(fenParts[5]) ?? 1;
      }
    }
    
    // Recursive rendering
    return Wrap(
      spacing: 2,
      runSpacing: 4,
      children: _buildMoveWidgets(_roots, startMoveNumber, startIsWhite, isFirstMove: true),
    );
  }
  
  List<Widget> _buildMoveWidgets(List<PgnMove> siblings, int moveNumber, bool isWhite, {bool isFirstMove = false}) {
    final widgets = <Widget>[];
    if (siblings.isEmpty) return widgets;
    
    final main = siblings[0];
    
    // Main move - show move number for White, or "X..." for Black on first move
    if (isWhite) {
      widgets.add(Text('$moveNumber. ', style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)));
    } else if (isFirstMove) {
      // Black's first move needs the "X..." notation
      widgets.add(Text('$moveNumber... ', style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)));
    }
    
    widgets.add(_buildSingleMoveWidget(main));
    
    // Check for variations (siblings 1+)
    if (siblings.length > 1) {
       for (int i = 1; i < siblings.length; i++) {
         widgets.add(const Text(' ( ', style: TextStyle(color: Colors.grey)));
         
         final variant = siblings[i];
         if (isWhite) {
            widgets.add(Text('$moveNumber. ', style: const TextStyle(color: Colors.grey)));
         } else {
            widgets.add(Text('$moveNumber... ', style: const TextStyle(color: Colors.grey)));
         }
         
         widgets.add(_buildSingleMoveWidget(variant));
         
         // Recursively build the rest of the variation
         widgets.addAll(_buildMoveWidgets(variant.children, isWhite ? moveNumber : moveNumber + 1, !isWhite));
         
         widgets.add(const Text(' ) ', style: TextStyle(color: Colors.grey)));
       }
    }
    
    // Continue main line
    widgets.addAll(_buildMoveWidgets(main.children, isWhite ? moveNumber : moveNumber + 1, !isWhite));
    
    return widgets;
  }

  Widget _buildSingleMoveWidget(PgnMove move) {
    final isSelected = move.id == _selectedMoveId;
    final isCurrent = _currentPath.any((m) => m.id == move.id);
    
    Color textColor = Colors.blue[300]!;
    Color? bgColor;
    if (isSelected) {
      textColor = Colors.white;
      bgColor = Colors.blue[700];
    } else if (isCurrent) {
      textColor = Colors.orange;
      bgColor = Colors.grey[800];
    }
    
    return GestureDetector(
      onTap: () => _goToMove(move.id),
      onSecondaryTapDown: (d) => _showContextMenu(move.id, d.globalPosition),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(2),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          move.san,
          style: TextStyle(
            color: textColor,
            fontWeight: isSelected || isCurrent ? FontWeight.bold : FontWeight.normal,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
  
  Widget _buildContextMenu() {
    String moveName = 'Move';
    final path = <PgnMove>[];
    if (_contextMenuMoveId != null && _findPathRecursive(_roots, _contextMenuMoveId!, path)) {
      moveName = path.last.san;
    }

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _hideContextMenu, 
        onSecondaryTap: _hideContextMenu, 
        child: Stack(
          children: [
            Positioned(
              left: _contextMenuPosition.dx,
              top: _contextMenuPosition.dy,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                color: Colors.grey[850],
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  constraints: const BoxConstraints(minWidth: 180),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Colors.grey[700]!),
                          ),
                        ),
                        child: Text(
                          moveName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      _buildContextMenuItem(
                        icon: Icons.comment,
                        text: 'Add Comment',
                        onTap: _addComment,
                      ),
                      _buildContextMenuItem(
                        icon: Icons.arrow_upward,
                        text: 'Promote to Mainline',
                        onTap: _promoteVariation,
                      ),
                      _buildContextMenuItem(
                        icon: Icons.content_copy,
                        text: 'Copy PGN from Here',
                        onTap: _copyPgnFromHere,
                      ),
                      const Divider(height: 1),
                      _buildContextMenuItem(
                        icon: Icons.delete_outline,
                        text: 'Delete from Here',
                        onTap: _deleteFromHere,
                        color: Colors.red[300],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
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
