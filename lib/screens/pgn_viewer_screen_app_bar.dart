// Page chrome for game reading. Optional activities have one labelled menu.
part of 'pgn_viewer_screen.dart';

mixin _AppBarBuildersMixin
    on State<PgnViewerScreen>, _RepertoireGenerationMixin {
  bool get _editMode;
  bool get _onLineTab;
  bool get _onReferenceTab;
  bool get _viewingStudy;
  set _singleGameFocus(bool value);
  GameViewPreferences get _viewPreferences;
  void _setViewPreferences(GameViewPreferences value);
  int get _lineTabIndex;
  int get _explorerTabIndex;
  int get _analysisTabIndex;
  void _showPanel(int index);
  Future<void> _checkDatabase();
  PgnViewerHandle get _activeMovetextController;
  PgnViewerWidgetController get _pgnWidgetController;
  PgnViewerWidgetController get _lineWidgetController;
  void _toggleEditMode();
  Future<void> _editInStudy();
  Future<void> _addCurrentGameToStudy();
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
        if (_controller.filteredGames.isNotEmpty &&
            !_controller.isSolitaireMode)
          _buildAddTabMenu(),
        _buildViewMenu(),
        const AppModeSwitcher(),
        AppSettingsButton(
          mode: AppMode.pgnViewer,
          contentBuilder: (_) => _gameViewSettings(),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildAddTabMenu({bool compact = false}) => AppOverflowMenu(
    label: compact ? null : 'Add tab',
    anchor: compact
        ? const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.add, size: 18, color: AppColors.onSurfaceMuted),
          )
        : null,
    tooltip: 'Add a workspace tab',
    entries: [
      AppMenuEntry(
        label: 'Check against database…',
        icon: Icons.storage_outlined,
        onRun: _checkDatabase,
      ),
      AppMenuEntry(label: 'My books', onRun: () => _showPanel(_lineTabIndex)),
      AppMenuEntry(
        label: 'Opening explorer',
        onRun: () => _showPanel(_explorerTabIndex),
      ),
      AppMenuEntry(
        label: 'Analysis',
        onRun: () => _showPanel(_analysisTabIndex),
      ),
      AppMenuEntry(
        label: 'Collection opening tree',
        shortcut: AppShortcut.toggleOpeningTree.label,
        onRun: () => _showPanel(PgnWorkspace.tree),
      ),
      AppMenuEntry(
        label: 'Database operations',
        onRun: () => _showPanel(PgnWorkspace.collection),
      ),
    ],
  );

  Widget _buildViewMenu() {
    final hasGame = _controller.filteredGames.isNotEmpty;
    final solitaire = _controller.isSolitaireMode;
    return AppOverflowMenu(
      label: 'Actions',
      tooltip: 'Actions',
      entries: [
        if (!hasGame) ...[
          AppMenuEntry(
            label: 'Open PGN file…',
            onRun: () => unawaited(_pickFile()),
          ),
          AppMenuEntry(
            label: 'Paste PGN',
            shortcut: 'Ctrl+V',
            onRun: () => unawaited(_pastePgn()),
          ),
        ],
        if (hasGame) ...[
          if (!solitaire && !_onReferenceTab)
            AppMenuEntry(
              label: _editMode ? 'Finish editing' : 'Edit game',
              icon: Icons.edit_outlined,
              enabled: !_onLineTab,
              onRun: _toggleEditMode,
            ),
          AppMenuEntry(
            label: _viewingStudy && !_onReferenceTab
                ? 'Edit study'
                : 'Save game to study…',
            onRun: _viewingStudy && !_onReferenceTab
                ? _editInStudy
                : _addCurrentGameToStudy,
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
            label: solitaire ? 'Leave solitaire chess' : 'Solitaire chess',
            enabled: !_controller.showOpeningTree && !_onReferenceTab,
            shortcut: AppShortcut.solitaire.label,
            onRun: _toggleSolitaireMode,
          ),
        ],
        if (_controller.totalTrophyCount > 0 || solitaire)
          AppMenuEntry(
            label: 'Solitaire chess trophies',
            onRun: _showTrophyCabinet,
          ),
      ],
    );
  }

  Widget _buildDatabaseTools() => PgnCollectionPanel(
    games: _controller.filteredGames,
    onSaveStudy: (games) async {
      if (!mounted) return;
      await addGamesToStudy(
        context,
        games: games,
        currentIndex: 0,
        chooseGames: false,
      );
      if (mounted) _reclaimFocus();
    },
    onExportPgn: _exportSlice,
    onExportScid: _exportSliceAsScid,
    onSeed: _generateRepertoireFromGames,
    onTree: () => _showPanel(PgnWorkspace.tree),
  );

  Widget _gameViewSettings() => GameViewSettingsDialog(
    preferences: _viewPreferences,
    onAnalysis: () => _showPanel(_analysisTabIndex),
    perspective: _controller.perspective,
    onChanged: _setViewPreferences,
    onFlip: _controller.toggleBoardFlipped,
    onPerspective: _controller.setPerspective,
    player: _controller.detectProtagonist(),
    onReadingOptions: _controller.filteredGames.isEmpty
        ? null
        : (_onLineTab ? _lineWidgetController : _pgnWidgetController)
              .showReadingOptions,
    onFullscreen:
        _controller.filteredGames.isNotEmpty && !_onLineTab && !_onReferenceTab
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
