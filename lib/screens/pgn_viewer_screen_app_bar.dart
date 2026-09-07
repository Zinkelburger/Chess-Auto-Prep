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
    final hasGame = _controller.filteredGames.isNotEmpty;
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
            Tooltip(
              message: _controller.hasActiveFilters
                  ? _controller.activeSliceConfig.chipLabels.join(' · ')
                  : 'Filter by player, date, result, or position',
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.standard,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                onPressed: _openSliceDialog,
                icon: const Icon(Icons.filter_list, size: 20),
                label: Text(
                  _controller.hasActiveFilters
                      ? 'Filters · ${_controller.filteredGames.length}/${_controller.allGames.length}'
                      : 'Filter games',
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (hasGame)
          if (_viewingStudy)
            TextButton(onPressed: _editInStudy, child: const Text('Edit study'))
          else
            MenuAnchor(
              builder: (context, menu, _) => TextButton(
                onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                child: const Text('Add to study'),
              ),
              menuChildren: [
                MenuItemButton(
                  onPressed: _addCurrentGameToStudy,
                  child: const Text('This game…'),
                ),
                if (_controller.filteredGames.length > 1)
                  MenuItemButton(
                    onPressed: _saveSliceAsStudy,
                    child: const Text('Choose games from this collection…'),
                  ),
              ],
            ),
        _buildViewMenu(),
        const AppModeSwitcher(),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildViewMenu() {
    final hasGame = _controller.filteredGames.isNotEmpty;
    final solitaire = _controller.isSolitaireMode;
    final prefs = _viewPreferences;
    return MenuAnchor(
      builder: (context, menu, _) => TextButton(
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        child: const Text('View'),
      ),
      menuChildren: [
        if (hasGame && !solitaire) ...[
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                onPressed: () => _showPanel(0),
                child: const Text('Game moves'),
              ),
              MenuItemButton(
                onPressed: () => _showPanel(_lineTabIndex),
                child: const Text('My repertoire'),
              ),
              MenuItemButton(
                onPressed: () => _showPanel(_explorerTabIndex),
                child: const Text('Opening explorer'),
              ),
              MenuItemButton(
                onPressed: () => _showPanel(_analysisTabIndex),
                child: const Text('Game analysis…'),
              ),
              MenuItemButton(
                onPressed: _controller.toggleOpeningTree,
                child: Text(
                  _controller.showOpeningTree
                      ? 'Return to game'
                      : 'Collection opening tree',
                ),
              ),
            ],
            child: const Text('Explore this game'),
          ),
          MenuItemButton(
            onPressed: _controller.showOpeningTree
                ? null
                : _toggleSolitaireMode,
            child: const Text('Solitaire chess'),
          ),
        ],
        if (hasGame && solitaire)
          MenuItemButton(
            onPressed: _toggleSolitaireMode,
            child: const Text('Leave solitaire chess'),
          ),
        SubmenuButton(
          menuChildren: [
            CheckboxMenuButton(
              value: prefs.engine,
              onChanged: (v) => _setViewPreferences(prefs.copyWith(engine: v)),
              child: const Text('Live engine controls'),
            ),
            CheckboxMenuButton(
              value: prefs.graph,
              onChanged: (v) => _setViewPreferences(prefs.copyWith(graph: v)),
              child: const Text('Saved analysis graph'),
            ),
            CheckboxMenuButton(
              value: prefs.playback,
              onChanged: (v) =>
                  _setViewPreferences(prefs.copyWith(playback: v)),
              child: const Text('Playback controls'),
            ),
            if (prefs.playback) ...[
              SubmenuButton(
                menuChildren: [
                  for (final speed in kAutoPlaySpeeds)
                    MenuItemButton(
                      onPressed: () =>
                          _setViewPreferences(prefs.copyWith(speed: speed)),
                      leadingIcon: speed == prefs.speed
                          ? const Icon(Icons.check, size: 16)
                          : null,
                      child: Text('${speed}s per move'),
                    ),
                ],
                child: const Text('Playback speed'),
              ),
              CheckboxMenuButton(
                value: prefs.autoNext,
                onChanged: (v) =>
                    _setViewPreferences(prefs.copyWith(autoNext: v)),
                child: const Text('Continue to next game'),
              ),
            ],
            if (hasGame)
              MenuItemButton(
                onPressed: () =>
                    (_onLineTab ? _lineWidgetController : _pgnWidgetController)
                        .showReadingOptions(),
                child: const Text('Move list…'),
              ),
            const Divider(),
            MenuItemButton(
              onPressed: _controller.toggleBoardFlipped,
              child: const Text('Flip board'),
            ),
            SubmenuButton(
              menuChildren: [
                MenuItemButton(
                  onPressed: () => _controller.setPerspective(
                    const Perspective(mode: PerspectiveMode.white),
                  ),
                  child: const Text('Always White'),
                ),
                MenuItemButton(
                  onPressed: () => _controller.setPerspective(
                    const Perspective(mode: PerspectiveMode.black),
                  ),
                  child: const Text('Always Black'),
                ),
                if (_controller.detectProtagonist() case final player?)
                  MenuItemButton(
                    onPressed: () => _controller.setPerspective(
                      Perspective(
                        mode: PerspectiveMode.player,
                        playerName: player,
                      ),
                    ),
                    child: Text('Follow $player'),
                  ),
              ],
              child: const Text('Board orientation'),
            ),
            MenuItemButton(
              onPressed: hasGame && !_onLineTab
                  ? _controller.toggleFullScreen
                  : null,
              child: const Text('Fullscreen'),
            ),
            const Divider(),
            MenuItemButton(
              onPressed: () => _setViewPreferences(const GameViewPreferences()),
              child: const Text('Restore simple defaults'),
            ),
          ],
          child: const Text('Customize view'),
        ),
        if (hasGame)
          SubmenuButton(
            menuChildren: [
              if (!solitaire)
                MenuItemButton(
                  onPressed: _onLineTab ? null : _toggleEditMode,
                  child: Text(_editMode ? 'Finish amending' : 'Amend game'),
                ),
              MenuItemButton(
                onPressed: _copyCurrentGamePgn,
                child: const Text('Copy game PGN'),
              ),
              if (_activeMovetextController.hasEphemeralMoves)
                MenuItemButton(
                  onPressed: () {
                    _controller.stopAutoPlay();
                    _activeMovetextController.clearEphemeralMoves();
                    setState(() {});
                    _reclaimFocus();
                  },
                  child: const Text('Clear analysis marks'),
                ),
              if (_viewingStudy)
                MenuItemButton(
                  onPressed: _addCurrentGameToStudy,
                  child: const Text('Copy game to another study…'),
                ),
              SubmenuButton(
                menuChildren: [
                  MenuItemButton(
                    onPressed: () =>
                        _controller.setSortMode(GameSortMode.fileOrder),
                    child: const Text('File order'),
                  ),
                  MenuItemButton(
                    onPressed: () =>
                        _controller.setSortMode(GameSortMode.dateDesc),
                    child: const Text('Newest first'),
                  ),
                ],
                child: const Text('Sort games'),
              ),
              MenuItemButton(
                onPressed: _exportSlice,
                child: Text(
                  'Export ${_controller.filteredGames.length} games as PGN…',
                ),
              ),
              MenuItemButton(
                onPressed: _exportSliceAsScid,
                child: const Text('Export as Scid database…'),
              ),
              MenuItemButton(
                onPressed: _generateRepertoireFromGames,
                child: const Text('Seed a repertoire from these games…'),
              ),
            ],
            child: const Text('Game and collection'),
          ),
        if (_controller.totalTrophyCount > 0 || solitaire)
          MenuItemButton(
            onPressed: _showTrophyCabinet,
            child: const Text('Solitaire chess trophies'),
          ),
        const Divider(),
        MenuItemButton(
          onPressed: () => openAppSettings(context),
          child: const Text('App settings…'),
        ),
      ],
    );
  }

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
