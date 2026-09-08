// Page chrome for game reading. Optional activities have one labelled menu.
part of 'pgn_viewer_screen.dart';

mixin _AppBarBuildersMixin
    on State<PgnViewerScreen>, _RepertoireGenerationMixin {
  bool get _editMode;
  bool get _onLineTab;
  bool get _viewingStudy;
  set _singleGameFocus(bool value);
  GameViewPreferences get _viewPreferences;
  void _setViewPreferences(GameViewPreferences value);
  int get _lineTabIndex;
  int get _explorerTabIndex;
  int get _analysisTabIndex;
  void _showPanel(int index);
  PgnViewerHandle get _activeMovetextController;
  PgnViewerWidgetController get _pgnWidgetController;
  PgnViewerWidgetController get _lineWidgetController;
  void _toggleEditMode();
  Future<void> _editInStudy();
  Future<void> _addCurrentGameToStudy();
  Future<void> _saveSliceAsStudy();
  Future<void> _copyCurrentGamePgn();
  void _openSliceDialog();
  void _showTrophyCabinet();
  Future<void> _exportSlice();
  Future<void> _exportSliceAsScid();
  Future<void> _pickFile();
  Future<void> _pastePgn();
  Future<void> _loadFile(String path);
  void _closeFile();
  bool _toggleSolitaireMode();
  @override
  void _reclaimFocus();

  PreferredSizeWidget _buildAppBar(ThemeData theme) {
    final loaded = _controller.allGames.isNotEmpty;
    final fileName = _controller.filePath == null
        ? (loaded ? 'Pasted games' : '')
        : p.basenameWithoutExtension(_controller.filePath!);
    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          Flexible(
            child: AppBarTitleWithTrail(
              title: _buildOpenPgnMenuButton(fileName),
            ),
          ),
          if (loaded && !_controller.isSolitaireMode) ...[
            const SizedBox(width: 12),
            AppOverflowMenu(
              label: _controller.hasActiveFilters
                  ? 'Filters · ${_controller.filteredGames.length}/${_controller.allGames.length}'
                  : 'Filter games',
              tooltip: 'Filter games',
              entries: [
                AppMenuEntry(
                  heading: 'Filter',
                  label: 'Choose filters…',
                  onRun: _openSliceDialog,
                ),
                if (_controller.hasActiveFilters)
                  AppMenuEntry(
                    label: 'Clear filters',
                    onRun: _controller.resetFilters,
                  ),
                AppMenuEntry(
                  heading: 'Sort',
                  label: 'File order',
                  checked: _controller.sortMode == GameSortMode.fileOrder,
                  onRun: () => _controller.setSortMode(GameSortMode.fileOrder),
                ),
                AppMenuEntry(
                  label: 'Newest first',
                  checked: _controller.sortMode == GameSortMode.dateDesc,
                  onRun: () => _controller.setSortMode(GameSortMode.dateDesc),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        _buildViewMenu(),
        const SizedBox(width: 16),
        const AppModeSwitcher(),
        AppSettingsButton(
          mode: AppMode.pgnViewer,
          contentBuilder: (_) => _gameViewSettings(),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildViewMenu() {
    final hasGame = _controller.filteredGames.isNotEmpty;
    final solitaire = _controller.isSolitaireMode;
    return AppOverflowMenu(
      label: 'Actions',
      tooltip: 'Actions',
      entries: [
        if (hasGame && !solitaire) ...[
          AppMenuEntry(
            heading: 'Explore',
            label: 'Game moves',
            onRun: () => _showPanel(0),
          ),
          AppMenuEntry(
            label: 'My repertoire',
            onRun: () => _showPanel(_lineTabIndex),
          ),
          AppMenuEntry(
            label: 'Opening explorer',
            onRun: () => _showPanel(_explorerTabIndex),
          ),
          AppMenuEntry(
            label: 'Game analysis…',
            onRun: () => _showPanel(_analysisTabIndex),
          ),
          AppMenuEntry(
            label: _controller.showOpeningTree
                ? 'Return to game'
                : 'Collection opening tree',
            shortcut: AppShortcut.toggleOpeningTree.label,
            onRun: _controller.toggleOpeningTree,
          ),
          AppMenuEntry(
            label: 'Solitaire chess',
            enabled: !_controller.showOpeningTree,
            shortcut: AppShortcut.solitaire.label,
            onRun: _toggleSolitaireMode,
          ),
        ],
        if (hasGame && solitaire)
          AppMenuEntry(
            heading: 'Play',
            label: 'Leave solitaire chess',
            onRun: _toggleSolitaireMode,
          ),
        if (_controller.totalTrophyCount > 0 || solitaire)
          AppMenuEntry(
            label: 'Solitaire chess trophies',
            onRun: _showTrophyCabinet,
          ),
        if (hasGame) ...[
          AppMenuEntry(
            heading: 'Study',
            label: _viewingStudy ? 'Edit study' : 'Save game to study…',
            onRun: _viewingStudy ? _editInStudy : _addCurrentGameToStudy,
          ),
          if (_controller.filteredGames.length > 1)
            AppMenuEntry(
              label: 'Save selected games to study…',
              onRun: _saveSliceAsStudy,
            ),
          if (_viewingStudy)
            AppMenuEntry(
              label: 'Copy game to another study…',
              onRun: _addCurrentGameToStudy,
            ),
          if (!solitaire)
            AppMenuEntry(
              label: _editMode ? 'Finish amending' : 'Amend game',
              enabled: !_onLineTab,
              onRun: _toggleEditMode,
            ),
          AppMenuEntry(label: 'Copy game PGN', onRun: _copyCurrentGamePgn),
          if (_activeMovetextController.hasEphemeralMoves)
            AppMenuEntry(
              label: 'Clear analysis marks',
              onRun: () {
                if (!mounted) return;
                _controller.stopAutoPlay();
                _activeMovetextController.clearEphemeralMoves();
                setState(() {});
                _reclaimFocus();
              },
            ),
          AppMenuEntry(
            heading: 'Collection',
            label: 'Export ${_controller.filteredGames.length} games as PGN…',
            onRun: _exportSlice,
          ),
          AppMenuEntry(
            label: 'Export as Scid database…',
            onRun: _exportSliceAsScid,
          ),
          AppMenuEntry(
            label: 'Seed a repertoire from these games…',
            onRun: _generateRepertoireFromGames,
          ),
        ],
      ],
    );
  }

  Widget _gameViewSettings() => GameViewSettingsDialog(
    preferences: _viewPreferences,
    perspective: _controller.perspective,
    onChanged: _setViewPreferences,
    onFlip: _controller.toggleBoardFlipped,
    onPerspective: _controller.setPerspective,
    player: _controller.detectProtagonist(),
    onReadingOptions: _controller.filteredGames.isEmpty
        ? null
        : (_onLineTab ? _lineWidgetController : _pgnWidgetController)
              .showReadingOptions,
    onFullscreen: _controller.filteredGames.isNotEmpty && !_onLineTab
        ? _controller.toggleFullScreen
        : null,
    embedded: true,
  );

  /// App-bar file button: shows the loaded file name and opens a menu with
  /// recent files, a file browser, paste-from-clipboard, and — once something
  /// is loaded — the way back out to the start screen.
  Widget _buildOpenPgnMenuButton(String fileName) {
    final hasCollection =
        _controller.allGames.isNotEmpty || _controller.filePath != null;
    return PopupMenuButton<String>(
      tooltip: 'Open games — recent files, browse, or paste',
      onSelected: (value) {
        if (value == 'browse') {
          unawaited(_pickFile());
        } else if (value == 'paste') {
          unawaited(_pastePgn());
        } else if (value == 'close') {
          _closeFile();
        } else if (value.startsWith('recent:')) {
          _singleGameFocus = false;
          unawaited(_loadFile(value.substring('recent:'.length)));
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
        // The way back out. Without it the viewer has no "nothing open" state
        // once a file has been opened — every route through this menu swaps
        // one collection for another.
        if (hasCollection) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'close',
            child: ListTile(
              leading: Icon(Icons.close, size: 20),
              title: Text('Close file — back to the start screen'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ],
      // IgnorePointer lets the PopupMenuButton's own tap region handle the
      // click while keeping the outlined-button look.
      child: IgnorePointer(
        child: TextButton(
          onPressed: () {},
          child: Text(
            fileName.isEmpty ? 'Open games' : fileName,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
