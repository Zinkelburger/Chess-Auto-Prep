import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import '../../../services/storage/file_mutation_service.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/explorer_response.dart';
import '../../../services/storage/app_paths.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/isolate_task.dart';
import '../../../design_system/components/list_search_field.dart';
import '../../../widgets/common/searchable_picker_dialog.dart';
import '../../../widgets/opening_explorer/explorer_move_row.dart';
import '../../../widgets/pgn/pgn_tree_games_list.dart';
import '../services/local_reference_database.dart';
import 'reference_game_dialog.dart';

class LocalReferencePane extends StatefulWidget {
  const LocalReferencePane({
    super.key,
    required this.fen,
    required this.onPlayMove,
    this.onAddMove,
    this.onHoverMove,
    this.repertoireMoves = const {},
    this.initialPath,
  });
  final String fen;
  final ValueChanged<String> onPlayMove;
  final ValueChanged<ExplorerMove>? onAddMove;
  final ValueChanged<ExplorerMove?>? onHoverMove;
  final Set<String> repertoireMoves;
  final String? initialPath;
  @override
  State<LocalReferencePane> createState() => _LocalReferencePaneState();
}

class _LocalReferencePaneState extends State<LocalReferencePane> {
  static const _recentKey = 'repertoire.reference_databases';
  static const _pageSize = 50;
  IsolateTask? _indexTask;
  IsolateTask? _queryTask;
  ReferenceIndex? _index;
  ReferencePosition? _position;
  List<String> _recent = [];
  String? _source;
  String? _error;
  bool _indexing = false;
  bool _loading = false;
  int _indexed = 0;
  int _sequence = 0;
  String _search = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() => _recent = prefs.getStringList(_recentKey) ?? []);
    } catch (_) {
      // Recent paths are optional; browsing a file still works.
    }
    if (!mounted || _source != null) return;
    final path = widget.initialPath ?? (_recent.isEmpty ? null : _recent.first);
    if (path != null) await _open(path);
  }

  @override
  void didUpdateWidget(covariant LocalReferencePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fen != widget.fen) unawaited(_query());
  }

  @override
  void dispose() {
    _sequence++;
    _debounce?.cancel();
    _indexTask?.cancel();
    _queryTask?.cancel();
    super.dispose();
  }

  Future<void> _browse() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pgn'],
    );
    if (mounted && file?.path != null) await _open(file!.path!);
  }

  Future<void> _chooseRecent() async {
    final path = await showSearchablePicker<String>(
      context: context,
      title: 'Local databases',
      searchHint: 'Search PGN files',
      selected: _source,
      items: [
        for (final path in _recent)
          PickerItem(
            value: path,
            label: p.basename(path),
            subtitle: p.dirname(path),
            icon: Icons.storage_outlined,
          ),
      ],
    );
    if (mounted && path != null) await _open(path);
  }

  Future<void> _open(String path) async {
    if (_indexing) return;
    _queryTask?.cancel();
    _sequence++;
    setState(() {
      _source = path;
      _index = null;
      _position = null;
      _error = null;
      _indexing = true;
      _indexed = 0;
    });
    Directory? staging;
    Directory? cacheRoot;
    try {
      final cache = await AppPaths.cacheDirectory();
      if (!mounted) return;
      final cachePath = p.join(cache.path, 'repertoire-reference');
      cacheRoot = await Directory(cachePath).create(recursive: true);
      staging = await cacheRoot.createTemp('import-');
      if (!mounted) return;
      final task = _indexTask = IsolateTask();
      final result = await task.run(
        _indexWork(path, cachePath, staging.path),
        timeout: const Duration(hours: 4),
        onProgress: (value) {
          if (mounted && value is int) setState(() => _indexed = value);
        },
      );
      if (!mounted) return;
      setState(() {
        _index = result;
        _recent = [
          path,
          ..._recent.where((item) => item != path),
        ].take(8).toList();
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentKey, _recent);
      if (mounted) await _query();
    } on IsolateTaskCancelled {
      if (mounted) {
        setState(() {
          _source = null;
          _index = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not index this PGN: $e');
    } finally {
      if (staging != null && cacheRoot != null) {
        try {
          await FileMutationService.instance.deleteDisposableDirectory(
            staging,
            allowedRoot: cacheRoot,
          );
        } on FileSystemException {
          // A failed cleanup leaves only disposable cache data.
        }
      }
      if (mounted) setState(() => _indexing = false);
    }
  }

  Future<void> _query({int offset = 0}) async {
    final index = _index;
    if (index == null || !mounted) return;
    _debounce?.cancel();
    final sequence = ++_sequence;
    _queryTask?.cancel();
    final task = _queryTask = IsolateTask();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await task.compute(queryReferencePosition, (
        path: index.path,
        fen: widget.fen,
        search: _search,
        offset: offset,
        limit: _pageSize,
      ));
      if (mounted && sequence == _sequence) setState(() => _position = result);
    } on IsolateTaskCancelled {
      // Only the latest board position or search is allowed to land.
    } catch (e) {
      if (mounted && sequence == _sequence) {
        setState(() => _error = 'Could not read this database: $e');
      }
    } finally {
      if (mounted && sequence == _sequence) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          children: [
            const Icon(
              Icons.storage_outlined,
              size: 16,
              color: AppColors.onSurfaceMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: _source ?? 'Choose a local PGN database',
                child: Text(
                  _source == null
                      ? 'Your games, on this computer'
                      : '${p.basename(_source!)}${_index == null ? '' : ' · ${formatExplorerCount(_index!.games)} games'}',
                  style: AppTextStyles.muted,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (_indexing)
              TextButton(
                onPressed: () => _indexTask?.cancel(),
                child: const Text('Cancel'),
              ),
            if (_recent.length > 1)
              IconButton(
                tooltip: 'Recent local databases',
                onPressed: _indexing ? null : _chooseRecent,
                icon: const Icon(Icons.history, size: 18),
              ),
            TextButton.icon(
              onPressed: _indexing ? null : _browse,
              icon: const Icon(Icons.folder_open, size: 16),
              label: Text(_source == null ? 'Open PGN…' : 'Change…'),
            ),
            if (_source != null)
              IconButton(
                tooltip: 'Refresh from PGN file',
                onPressed: _indexing ? null : () => _open(_source!),
                icon: const Icon(Icons.refresh, size: 18),
              ),
          ],
        ),
      ),
      if (_loading || _indexing)
        const LinearProgressIndicator(minHeight: 2)
      else
        const Divider(height: 2),
      Expanded(child: _body()),
    ],
  );

  Widget _body() {
    if (_error != null) {
      return _message(
        _error!,
        action: TextButton(
          onPressed: () => _index == null ? _open(_source!) : _query(),
          child: const Text('Retry'),
        ),
      );
    }
    if (_indexing && _position == null) {
      return _message(
        'Indexing ${formatExplorerCount(_indexed)} games…\nYou can keep working on the board.',
      );
    }
    if (_source == null) {
      return _message(
        'Explore your own PGN database\nMoves, results and matching games follow the board.',
        action: TextButton.icon(
          onPressed: _browse,
          icon: const Icon(Icons.folder_open),
          label: const Text('Choose PGN file'),
        ),
      );
    }
    final data = _position;
    if (data == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final moves = _moves(data);
        final games = _games(data);
        final content = constraints.maxWidth >= 700
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: constraints.maxWidth * .42, child: moves),
                  const VerticalDivider(width: 1),
                  Expanded(child: games),
                ],
              )
            : DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    const TabBar(
                      tabs: [
                        Tab(text: 'Moves', height: 30),
                        Tab(text: 'Games', height: 30),
                      ],
                    ),
                    Expanded(child: TabBarView(children: [moves, games])),
                  ],
                ),
              );
        return AbsorbPointer(
          absorbing: _loading,
          child: Opacity(opacity: _loading ? .45 : 1, child: content),
        );
      },
    );
  }

  Widget _moves(ReferencePosition data) {
    final total = data.moves.fold(0, (n, m) => n + m.games);
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.only(right: widget.onAddMove == null ? 0 : 30),
          child: const ExplorerTableHeader(),
        ),
        Expanded(
          child: data.moves.isEmpty
              ? _message('No continuations at this position.')
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: data.moves.length,
                  itemBuilder: (_, i) {
                    final move = data.moves[i];
                    final explorerMove = ExplorerMove(
                      san: move.san,
                      uci: move.uci,
                      white: move.white,
                      draws: move.draws,
                      black: move.black,
                      playRate: total == 0 ? 0 : move.games / total * 100,
                    );
                    return Row(
                      children: [
                        Expanded(
                          child: ExplorerMoveRow(
                            san: move.san,
                            games: move.games,
                            wins: move.white,
                            draws: move.draws,
                            losses: move.black,
                            playFraction: total == 0 ? 0 : move.games / total,
                            inRepertoire: widget.repertoireMoves.contains(
                              move.san,
                            ),
                            onPlay: () {
                              if (mounted && !_loading) {
                                widget.onPlayMove(move.san);
                              }
                            },
                            onHover: (hover) {
                              if (mounted) {
                                widget.onHoverMove?.call(
                                  hover ? explorerMove : null,
                                );
                              }
                            },
                            onAdd: widget.onAddMove == null
                                ? null
                                : () {
                                    if (mounted && !_loading) {
                                      widget.onAddMove!(explorerMove);
                                    }
                                  },
                          ),
                        ),
                        if (widget.onAddMove != null)
                          SizedBox(
                            width: 30,
                            height: 26,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              tooltip: widget.repertoireMoves.contains(move.san)
                                  ? '${move.san} is in your repertoire'
                                  : 'Add ${move.san} to repertoire',
                              icon: Icon(
                                widget.repertoireMoves.contains(move.san)
                                    ? Icons.check
                                    : Icons.add,
                                size: 16,
                              ),
                              onPressed:
                                  widget.repertoireMoves.contains(move.san)
                                  ? null
                                  : () {
                                      if (mounted && !_loading) {
                                        widget.onAddMove!(explorerMove);
                                      }
                                    },
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            'Mainline games · results from White’s side${_index!.skipped == 0 ? '' : ' · ${_index!.skipped} skipped'}',
            style: AppTextStyles.caption,
          ),
        ),
      ],
    );
  }

  Widget _games(ReferencePosition data) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(6),
        child: ListSearchField(
          hintText: 'Search matching games: player, event, ECO',
          onChanged: (value) {
            if (!mounted) return;
            _search = value;
            _debounce?.cancel();
            _debounce = Timer(
              const Duration(milliseconds: 250),
              () => _query(),
            );
          },
        ),
      ),
      Expanded(
        child: data.games.isEmpty
            ? _message('No matching games at this position.')
            : PgnTreeGamesList(
                games: data.games,
                currentFen: widget.fen,
                currentIndex: -1,
                initiallyShowMoves: false,
                showToolbar: false,
                onGameSelected: (i) {
                  if (mounted && !_loading) {
                    unawaited(
                      showReferenceGame(context, data.games[i], widget.fen),
                    );
                  }
                },
              ),
      ),
      SizedBox(
        height: 30,
        child: Row(
          children: [
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                data.total == 0
                    ? '0 games'
                    : '${data.offset + 1}–${data.offset + data.games.length} of ${formatExplorerCount(data.total)} games',
                style: AppTextStyles.caption,
              ),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              tooltip: 'Previous games',
              onPressed: data.offset == 0
                  ? null
                  : () => _query(offset: data.offset - _pageSize),
              icon: const Icon(Icons.chevron_left, size: 18),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              tooltip: 'Next games',
              onPressed: data.offset + data.games.length >= data.total
                  ? null
                  : () => _query(offset: data.offset + _pageSize),
              icon: const Icon(Icons.chevron_right, size: 18),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _message(String text, {Widget? action}) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center, style: AppTextStyles.muted),
            ?action,
          ],
        ),
      ),
    ),
  );
}

// Bind only plain data; no widget state can cross the isolate boundary.
Future<ReferenceIndex> Function(SendPort) _indexWork(
  String source,
  String cache,
  String staging,
) =>
    (port) => buildReferenceIndex(
      ReferenceIndexRequest(source, cache, port, stagingDirectory: staging),
    );
