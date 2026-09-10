// Page chrome for game reading. Optional activities have one labelled menu.
part of 'pgn_viewer_screen.dart';

mixin _AppBarBuildersMixin on State<PgnViewerScreen> {
  PgnViewerController get _controller;
  bool get _editMode;
  bool get _canReturnToFilters;
  void _returnToFilters();
  bool get _onLineTab;
  bool get _onReferenceTab;
  bool get _viewingStudy;
  set _singleGameFocus(bool value);
  GameViewPreferences get _viewPreferences;
  void _setViewPreferences(GameViewPreferences value);
  int get _analysisTabIndex;
  void _showPanel(int index);
  PgnViewerHandle get _activeMovetextController;
  PgnViewerWidgetController get _pgnWidgetController;
  PgnViewerWidgetController get _lineWidgetController;
  void _toggleEditMode();
  Future<void> _editInStudy();
  Future<void> _addCurrentGameToStudy();
  Future<void> _copyCurrentGamePgn({bool mainlineOnly = false});
  Future<void> _copyCurrentFen();
  void _openSliceDialog();
  Future<void> _exportSlice();
  Future<void> _exportSliceAsScid();
  Future<void> _pickFile();
  Future<void> _pastePgn();
  Future<void> _loadFile(String path);
  Future<void> _closeFile();
  Future<bool> _savePgn();
  bool _toggleSolitaireMode();
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
          if (_canReturnToFilters) ...[
            const SizedBox(width: 12),
            Flexible(
              child: TextButton.icon(
                key: const ValueKey('return-to-filters'),
                onPressed: _returnToFilters,
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('Back to filters'),
              ),
            ),
          ],
        ],
      ),
      actions: [
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

  bool get _showSaveAction =>
      _controller.filePath == null ||
      !_viewPreferences.autoSave ||
      (_controller.errorMessage != null && _controller.hasUnsavedChanges);

  Widget _buildViewMenu() {
    final hasGame = _controller.filteredGames.isNotEmpty;
    final solitaire = _controller.isSolitaireMode;
    return AppOverflowMenu(
      label: 'Actions',
      tooltip: 'Actions',
      openOnHover: true,
      entries: [
        if (!hasGame) ...[
          AppMenuEntry(
            label: 'Open PGN file…',
            icon: Icons.folder_open,
            onRun: () => unawaited(_pickFile()),
          ),
          AppMenuEntry(
            label: 'Paste PGN',
            icon: Icons.content_paste,
            shortcut: AppShortcut.pastePgn.label,
            onRun: () => unawaited(_pastePgn()),
          ),
        ],
        if (_controller.allGames.isNotEmpty && !solitaire)
          AppMenuEntry(
            label: 'Filter games',
            icon: Icons.filter_alt_outlined,
            onRun: _openSliceDialog,
          ),
        if (!solitaire)
          AppMenuEntry(
            label: _viewPreferences.autoSave
                ? 'Turn autosave off'
                : 'Turn autosave on',
            icon: Icons.save_outlined,
            onRun: () => _setViewPreferences(
              _viewPreferences.copyWith(autoSave: !_viewPreferences.autoSave),
            ),
          ),
        if (hasGame) ...[
          AppMenuEntry(
            label: _viewPreferences.showOpening
                ? 'Hide opening'
                : 'Show opening',
            icon: Icons.info_outline,
            onRun: () => _setViewPreferences(
              _viewPreferences.copyWith(
                showOpening: !_viewPreferences.showOpening,
              ),
            ),
          ),
          if (!solitaire && _showSaveAction)
            AppMenuEntry(
              icon: Icons.save_outlined,
              label: _controller.filePath == null ? 'Save as…' : 'Save PGN',
              enabled: !_controller.isSaving,
              onRun: () => unawaited(_savePgn()),
            ),
          if (!solitaire && !_onReferenceTab)
            AppMenuEntry(
              icon: Icons.edit_outlined,
              label: _editMode ? 'Finish editing' : 'Edit',
              enabled: !_onLineTab,
              onRun: _toggleEditMode,
            ),
          if (!solitaire) ...[
            AppMenuEntry(
              label: _viewPreferences.engine ? 'Hide Engine' : 'Show Engine',
              icon: Icons.memory,
              onRun: () {
                final show = !_viewPreferences.engine;
                _setViewPreferences(_viewPreferences.copyWith(engine: show));
                if (show) _showPanel(PgnWorkspace.game);
              },
            ),
            AppMenuEntry(
              heading: 'Explore',
              label: 'Evaluation graph',
              icon: Icons.show_chart,
              onRun: () => _showPanel(_analysisTabIndex),
            ),
            AppMenuEntry(
              label: 'Tree',
              icon: Icons.account_tree_outlined,
              onRun: () => _showPanel(PgnWorkspace.tree),
            ),
          ],
          AppMenuEntry(
            label: 'Copy Game PGN',
            icon: Icons.copy,
            dividerAbove: true,
            onRun: _copyCurrentGamePgn,
          ),
          AppMenuEntry(
            label: 'Copy mainline PGN (no comments)',
            icon: Icons.copy,
            onRun: () => _copyCurrentGamePgn(mainlineOnly: true),
          ),
          AppMenuEntry(
            label: 'Copy FEN',
            icon: Icons.copy,
            onRun: _copyCurrentFen,
          ),
          AppMenuEntry(
            label: 'Export',
            icon: Icons.file_upload_outlined,
            onRun: () {},
            children: [
              AppMenuEntry(
                heading: '${_controller.filteredGames.length} games in view',
                label: 'Export as PGN…',
                icon: Icons.description_outlined,
                onRun: _exportSlice,
              ),
              AppMenuEntry(
                label: 'Export as SCID…',
                icon: Icons.storage_outlined,
                onRun: _exportSliceAsScid,
              ),
              AppMenuEntry(
                icon: Icons.library_add_outlined,
                label: _viewingStudy && !_onReferenceTab
                    ? 'Edit study'
                    : 'Add to Study',
                onRun: _viewingStudy && !_onReferenceTab
                    ? _editInStudy
                    : _addCurrentGameToStudy,
              ),
            ],
          ),
          if (solitaire)
            AppMenuEntry(
              label: 'Leave solitaire chess',
              icon: Icons.exit_to_app,
              onRun: _toggleSolitaireMode,
            ),
        ],
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
    onTree: () => _showPanel(PgnWorkspace.tree),
  );

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
          unawaited(_closeFile());
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
