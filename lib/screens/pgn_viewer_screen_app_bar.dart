// Page chrome for game reading. Optional activities have one labelled menu.
part of 'pgn_viewer_screen.dart';

mixin _AppBarBuildersMixin on State<PgnViewerScreen> {
  ViewerDocumentController get _document;
  bool get _editMode;
  bool get _canReturnToFilters;
  void _returnToFilters();
  bool get _onLineTab;
  bool get _viewingStudy;
  set _singleGameFocus(bool value);
  GameViewPreferences get _viewPreferences;
  String? get _viewerError;
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
  Future<bool> _loadFile(String path);
  Future<void> _closeFile();
  Future<bool> _savePgn();
  bool _toggleSolitaireMode();
  void _reclaimFocus();

  PreferredSizeWidget _buildAppBar(ThemeData theme) {
    final loaded = _document.collection.games.isNotEmpty;
    final fileName = _document.collectionTitle ?? (loaded ? 'Pasted games' : '');
    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          Flexible(
            child: AppBarTitleWithTrail(
              title: _buildOpenPgnMenuButton(fileName),
            ),
          ),
          if (loaded) ...[
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: PgnSliceChips(
                config: _document.filters.selection.config,
                onRemoveChip: (index) =>
                    unawaited(_document.removeSliceChip(index)),
                onOpenSliceDialog: _openSliceDialog,
              ),
            ),
          ],
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
      _document.editor.needsSaveRecovery ||
      (_document.editor.state.outcome != null &&
          _document.editor.state.outcome is! PgnSaved) ||
      _document.editor.state.retainedDrafts.isNotEmpty ||
      _document.filePath == null ||
      !_viewPreferences.autoSave ||
      (_document.errorMessage != null && _document.editor.hasUnsavedChanges);

  Widget _buildViewMenu() {
    final hasGame = _document.collection.visibleGames.isNotEmpty;
    final solitaire = _document.reading.solitaire.isActive;
    return AppOverflowMenu(
      label: 'Actions',
      tooltip: 'Actions',
      openOnHover: true,
      entries: [
        if (!hasGame && _document.editor.state.retainedDrafts.isNotEmpty)
          AppMenuEntry(
            label: AppLocalizations.of(context).documentSaveRecovery,
            icon: Icons.save_outlined,
            onRun: () => unawaited(_savePgn()),
          ),
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
        if (_document.collection.games.isNotEmpty && !solitaire)
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
              label: AppLocalizations.of(context).documentSaveRecovery,
              enabled: !_document.editor.state.busy,
              onRun: () => unawaited(_savePgn()),
            ),
          if (!solitaire)
            AppMenuEntry(
              icon: Icons.edit_outlined,
              label: _editMode ? 'Finish editing' : 'Edit',
              enabled: !_onLineTab,
              onRun: _toggleEditMode,
            ),
          if (!solitaire) ...[
            AppMenuEntry(
              label: 'Compare against my books',
              icon: Icons.menu_book_outlined,
              onRun: () => _showPanel(PgnWorkspace.books),
            ),
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
                heading:
                    '${_document.collection.visibleGames.length} games in view',
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
                label: _viewingStudy ? 'Edit study' : 'Add to Study',
                onRun: _viewingStudy ? _editInStudy : _addCurrentGameToStudy,
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
    games: _document.collection.visibleGames,
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
    perspective: _document.presentation.perspective,
    onChanged: _setViewPreferences,
    onFlip: _document.presentation.toggleBoardFlipped,
    onPerspective: _document.setPerspective,
    player: _document.collection.detectProtagonist(),
    readingAnchor: (_onLineTab ? _lineWidgetController : _pgnWidgetController)
        .readingAnchor,
    onReadingOptionChanged: _document.collection.visibleGames.isEmpty
        ? null
        : (_onLineTab ? _lineWidgetController : _pgnWidgetController)
              .applyReadingOption,
    onFullscreen: _document.collection.visibleGames.isNotEmpty && !_onLineTab
        ? _document.presentation.toggleFullScreen
        : null,
    embedded: true,
  );

  /// App-bar file button: shows the loaded file name and opens a menu with
  /// recent files, a file browser, paste-from-clipboard, and — once something
  /// is loaded — the way back out to the start screen.
  Widget _buildOpenPgnMenuButton(String fileName) {
    final hasCollection =
        _document.collection.games.isNotEmpty || _document.filePath != null;
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
        for (final path in _document.libraryState.recentFiles)
          PopupMenuItem(
            value: 'recent:$path',
            enabled: path != _document.filePath,
            child: Tooltip(
              message: path,
              waitDuration: const Duration(milliseconds: 600),
              child: ListTile(
                leading: Icon(
                  path == _document.filePath
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
        if (_document.libraryState.recentFiles.isNotEmpty)
          const PopupMenuDivider(),
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
