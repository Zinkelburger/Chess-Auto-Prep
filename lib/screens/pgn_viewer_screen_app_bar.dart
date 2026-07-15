// App-bar builders for the PGN viewer: title row with the open-PGN menu and
// slice chips, plus the study-mode / board-view / file action groups.
// Part of pgn_viewer_screen.dart.
part of 'pgn_viewer_screen.dart';

/// App-bar builders, split out of [_PgnViewerScreenState]. Depends on
/// [_RepertoireGenerationMixin] for the overflow menu's generate action.
mixin _AppBarBuildersMixin
    on State<PgnViewerScreen>, _RepertoireGenerationMixin {
  bool get _editMode;
  void _toggleEditMode();
  void _openSliceDialog();
  void _showTrophyCabinet();
  Future<void> _exportSlice();
  Future<void> _pickFile();
  Future<void> _pastePgn();
  Future<void> _loadFile(String path);
  void _reclaimFocus();

  PreferredSizeWidget _buildAppBar(ThemeData theme) {
    final fileName = _controller.filePath != null
        ? p.basename(_controller.filePath!)
        : '';
    return AppBar(
      titleSpacing: 16,
      leading:
          !_controller.showOpeningTree &&
              !_controller.isSolitaireMode &&
              _controller.hasTreeReturnPosition
          ? IconButton(
              onPressed: _controller.returnToTreePosition,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to opening-tree position',
            )
          : null,
      title: Row(
        children: [
          const Text('PGN Viewer'),
          const SizedBox(width: 12),
          Flexible(child: _buildOpenPgnMenuButton(fileName)),
          if (_controller.allGames.isNotEmpty &&
              !_controller.isSolitaireMode) ...[
            const SizedBox(width: 8),
            Expanded(
              child: PgnSliceChips(
                controller: _controller,
                onOpenSliceDialog: _openSliceDialog,
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (_controller.filteredGames.isNotEmpty) ...[
          // Study modes: opening tree, amend, solitaire.
          if (!_controller.isSolitaireMode) ...[
            IconButton(
              onPressed: _controller.toggleOpeningTree,
              icon: Icon(
                Icons.account_tree,
                size: 20,
                color: _controller.showOpeningTree
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              tooltip: 'Opening tree (T)',
            ),
            IconButton(
              onPressed: _toggleEditMode,
              icon: Icon(
                _editMode ? Icons.edit : Icons.edit_outlined,
                size: 20,
                color: _editMode ? Theme.of(context).colorScheme.primary : null,
              ),
              tooltip:
                  'Amend game — moves, marks & comments '
                  'are saved to the file (A)',
            ),
          ],
          IconButton(
            onPressed: _controller.showOpeningTree
                ? null
                : _controller.toggleSolitaire,
            icon: Icon(
              Icons.psychology,
              size: 20,
              color: _controller.isSolitaireMode
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            tooltip: 'Solitaire mode (Shift+S)',
          ),
          if (_controller.isSolitaireMode && _controller.totalTrophyCount > 0)
            IconButton(
              onPressed: () => _showTrophyCabinet(),
              icon: const Icon(
                Icons.emoji_events,
                size: 20,
                color: Colors.amber,
              ),
              tooltip: 'Trophies (${_controller.totalTrophyCount})',
            ),
          _actionDivider(),
          // Board view: flip, perspective.
          IconButton(
            onPressed: _controller.toggleBoardFlipped,
            icon: const Icon(Icons.swap_vert, size: 20),
            tooltip: 'Flip board (F)',
          ),
          if (!_controller.isSolitaireMode) ...[
            PgnPerspectiveButton(controller: _controller),
            _actionDivider(),
            // File / misc: export, overflow.
            IconButton(
              onPressed: _exportSlice,
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: 'Export filtered games (Ctrl+E)',
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: 'More actions',
              onSelected: (value) {
                if (value == 'generate_repertoire') {
                  _generateRepertoireFromGames();
                } else if (value == 'trophies') {
                  _showTrophyCabinet();
                } else if (value == 'make_puzzle') {
                  context.read<AppState>().switchToPuzzleCreator(
                    seedFen: _controller.currentPosition.fen,
                  );
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'make_puzzle',
                  child: ListTile(
                    leading: Icon(Icons.extension, size: 20),
                    title: Text('Make puzzle from this position'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'generate_repertoire',
                  child: ListTile(
                    leading: Icon(Icons.auto_fix_high, size: 20),
                    title: Text('Generate repertoire from games'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'trophies',
                  child: ListTile(
                    leading: const Icon(
                      Icons.emoji_events,
                      size: 20,
                      color: Colors.amber,
                    ),
                    title: Text(
                      'Trophy cabinet (${_controller.totalTrophyCount})',
                    ),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ],
        const AppModeMenuButton(),
      ],
    );
  }

  /// App-bar file button: shows the loaded file name and opens a menu with
  /// recent files, a file browser, and paste-from-clipboard.
  Widget _buildOpenPgnMenuButton(String fileName) {
    return PopupMenuButton<String>(
      tooltip: 'Open PGN — recent files, browse, or paste',
      onSelected: (value) {
        if (value == 'browse') {
          _pickFile();
        } else if (value == 'paste') {
          _pastePgn();
        } else if (value.startsWith('recent:')) {
          _loadFile(value.substring('recent:'.length));
        }
      },
      onCanceled: _reclaimFocus,
      itemBuilder: (_) => [
        for (final path in _controller.recentFiles)
          PopupMenuItem(
            value: 'recent:$path',
            enabled: path != _controller.filePath,
            child: Tooltip(
              message: path,
              waitDuration: const Duration(milliseconds: 600),
              child: ListTile(
                leading: Icon(
                  path == _controller.filePath
                      ? Icons.check
                      : Icons.description_outlined,
                  size: 20,
                ),
                title: Text(p.basename(path), overflow: TextOverflow.ellipsis),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        if (_controller.recentFiles.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'browse',
          child: ListTile(
            leading: Icon(Icons.folder_open, size: 20),
            title: Text('Browse for file…'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: 'paste',
          child: ListTile(
            leading: Icon(Icons.content_paste, size: 20),
            title: Text('Paste PGN from clipboard (Ctrl+V)'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
      // IgnorePointer lets the PopupMenuButton's own tap region handle the
      // click while keeping the outlined-button look.
      child: IgnorePointer(
        child: OutlinedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.folder_open, size: 18),
          label: Text(
            fileName.isEmpty ? 'Open PGN' : fileName,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  /// Thin vertical separator between app-bar action groups.
  Widget _actionDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        height: 22,
        child: VerticalDivider(
          width: 1,
          thickness: 1,
          color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
