import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/pgn/pgn_collection_helpers.dart';
import '../../models/pgn_game_entry.dart';
import '../../services/pgn_parsing_service.dart';
import '../../services/storage/storage_factory.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/fen_utils.dart';
import '../game_nav_item.dart';
import '../game_search_dialog.dart';
import 'pgn_tree_games_list.dart';

typedef DatabaseIndex = ({
  List<PgnGameEntry> games,
  Map<String, List<int>> positions,
});
DatabaseIndex indexPgnDatabase(String content) {
  final games = parseMultiGamePgn(content);
  return (
    games: games,
    positions: buildFenIndex([
      for (final g in games) (headers: g.headers, pgnText: g.pgnText),
    ]),
  );
}

class PgnDatabasePanelController {
  Future<void> Function()? _search;
  Future<void> search() async {
    await _search?.call();
  }
}

/// A reference database follows the main board without replacing its game.
class PgnDatabasePanel extends StatefulWidget {
  const PgnDatabasePanel({
    super.key,
    required this.path,
    required this.fen,
    required this.onOpenGame,
    required this.controller,
  });
  final PgnDatabasePanelController controller;
  final String path;
  final String fen;
  final ValueChanged<PgnGameEntry> onOpenGame;
  @override
  State<PgnDatabasePanel> createState() => _PgnDatabasePanelState();
}

class _PgnDatabasePanelState extends State<PgnDatabasePanel> {
  DatabaseIndex? _data;
  String? _error;
  bool _positionOnly = true;
  @override
  void initState() {
    super.initState();
    widget.controller._search = _openSearch;
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.controller._search = null;
    super.dispose();
  }

  List<PgnGameEntry> get _games {
    final data = _data;
    if (data == null) return [];
    if (!_positionOnly) return data.games;
    return [
      for (final i in data.positions[normalizeFen(widget.fen)] ?? <int>[])
        data.games[i],
    ];
  }

  Future<void> _openSearch() async {
    if (!mounted) return;
    final games = _games;
    if (games.isEmpty) return;
    final selected = await showGameSearchDialog(
      context: context,
      games: [for (final g in games) GameNavItem.fromEntry(g)],
      currentIndex: 0,
    );
    if (mounted && selected != null) widget.onOpenGame(games[selected]);
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final content = await StorageFactory.instance.readFile(widget.path);
      if (content == null) throw StateError('The file could not be read.');
      final data = await compute(indexPgnDatabase, content);
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open database: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: AppTextStyles.muted),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    final data = _data;
    if (data == null) return const Center(child: CircularProgressIndicator());
    final matches = [
      for (final i in data.positions[normalizeFen(widget.fen)] ?? <int>[])
        data.games[i],
    ];
    final games = _positionOnly ? matches : data.games;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '${matches.length} of ${data.games.length} games reach this position',
            style: AppTextStyles.muted,
          ),
        ),
        CheckboxListTile(
          dense: true,
          value: _positionOnly,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('At board position', style: AppTextStyles.muted),
          subtitle: const Text(
            'Includes positions in variations',
            style: AppTextStyles.caption,
          ),
          onChanged: (v) {
            if (mounted) setState(() => _positionOnly = v!);
          },
        ),
        Expanded(
          child: games.isEmpty
              ? const Center(
                  child: Text(
                    'No games at this position.\nUncheck “At board position” to browse the database.',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.muted,
                  ),
                )
              : PgnTreeGamesList(
                  games: games,
                  currentFen: widget.fen,
                  currentIndex: 0,
                  onGameSelected: (i) {
                    if (mounted) widget.onOpenGame(games[i]);
                  },
                  onSearch: _openSearch,
                ),
        ),
      ],
    );
  }
}
