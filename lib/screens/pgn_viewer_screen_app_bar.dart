// App-bar builders for the PGN viewer: title row with the open-PGN menu and
// slice chips, plus the study-mode / board-view / file action groups.
// Part of pgn_viewer_screen.dart.
part of 'pgn_viewer_screen.dart';

/// App-bar builders, split out of [_PgnViewerScreenState]. Depends on
/// [_RepertoireGenerationMixin] for the overflow menu's generate action.
mixin _AppBarBuildersMixin
    on State<PgnViewerScreen>, _RepertoireGenerationMixin {
  bool get _editMode;

  /// True while the viewer is showing one game handed to it by name (from the
  /// recent-games list). See [_PgnViewerScreenState._openFromHandoff].
  bool get _singleGameFocus;
  set _singleGameFocus(bool value);

  void _toggleEditMode();
  Future<void> _editInStudy();
  Future<void> _saveSliceAsStudy();
  void _openSliceDialog();
  void _showTrophyCabinet();
  Future<void> _exportSlice();
  Future<void> _pickFile();
  Future<void> _pastePgn();
  Future<void> _loadFile(String path);
  void _closeFile();
  @override
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
              tooltip: actionTooltip(
                'Back to opening-tree position',
                shortcut: AppShortcut.toggleOpeningTree,
              ),
            )
          : null,
      title: AppBarTitleWithTrail(
        title: Row(
          children: [
            const Text('PGN Viewer'),
            const SizedBox(width: 12),
            Flexible(child: _buildOpenPgnMenuButton(fileName)),
            if (_controller.allGames.isNotEmpty &&
                !_controller.isSolitaireMode &&
                !_singleGameFocus) ...[
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
      ),
      actions: [
        if (_controller.filteredGames.isNotEmpty) ...[
          // What stays in the bar is the *view modes* — controls with an on
          // state you can see on the board. Everything that merely does
          // something once moved into the overflow below, which is what took
          // this bar from eleven controls to six.
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
              tooltip: actionTooltip(
                'Opening tree',
                shortcut: AppShortcut.toggleOpeningTree,
              ),
            ),
            IconButton(
              onPressed: _toggleEditMode,
              icon: Icon(
                _editMode ? Icons.edit : Icons.edit_outlined,
                size: 20,
                color: _editMode ? Theme.of(context).colorScheme.primary : null,
              ),
              tooltip: 'Amend game',
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
            tooltip: _controller.isSolitaireMode
                ? 'Exit solitaire mode (Esc)'
                : 'Solitaire mode (Ctrl+S)',
          ),
          // No group separators: the thin vertical rules read as part of the
          // button beside them ("what is that bar doing on my button?"), and
          // grouping by hairline was never worth that. Icons are spaced and
          // tooltipped instead.
          //
          // "Check this game against my repertoire" used to live here as a
          // fork icon that opened a dialog. It is the Line tab now — the
          // question belongs next to Game and Analysis, not in the toolbar.
          IconButton(
            onPressed: _controller.toggleBoardFlipped,
            icon: const Icon(Icons.swap_vert, size: 20),
            tooltip: 'Flip board (F)',
          ),
          if (!_controller.isSolitaireMode)
            PgnPerspectiveButton(controller: _controller),
        ],
        // One overflow for the whole bar, present in every state — solitaire
        // included, which is how the trophy cabinet and app settings stay
        // reachable there without icons of their own.
        AppOverflowMenu(entries: _overflowEntries()),
        const AppModeMenuButton(),
      ],
    );
  }

  List<AppMenuEntry> _overflowEntries() {
    final games = _controller.filteredGames;
    final plural = games.length == 1 ? '' : 's';
    return [
      if (games.isNotEmpty && !_controller.isSolitaireMode) ...[
        AppMenuEntry(
          label: 'Edit in Study',
          icon: Icons.edit_note,
          shortcut: 'A',
          onRun: _editInStudy,
        ),
        // Only while the chip bar is hidden — otherwise this duplicates the
        // "Slice" chip sitting in the title row.
        if (_singleGameFocus)
          AppMenuEntry(
            label: 'Filter these games…',
            icon: Icons.filter_alt_outlined,
            onRun: () {
              // Leaving single-game focus is the point of asking for filters:
              // the chip bar comes back with the dialog.
              setState(() => _singleGameFocus = false);
              _openSliceDialog();
            },
          ),
        AppMenuEntry(
          label: 'Export filtered games…',
          icon: Icons.file_upload_outlined,
          dividerAbove: true,
          onRun: _exportSlice,
        ),
        AppMenuEntry(
          label: 'Save ${games.length} filtered game$plural as study…',
          icon: Icons.edit_note,
          onRun: () => unawaited(_saveSliceAsStudy()),
        ),
        AppMenuEntry(
          label: 'Seed a repertoire from these games…',
          icon: Icons.auto_fix_high,
          onRun: () => unawaited(_generateRepertoireFromGames()),
          hint:
              'Creates a repertoire and hands the ${games.length} currently '
              'filtered game$plural to the Repertoire Builder\n'
              'as the seed for generation. The games become the starting move '
              'data; the builder then explores and scores lines from there.',
        ),
      ],
      if (_controller.totalTrophyCount > 0)
        AppMenuEntry(
          label: 'Trophy cabinet (${_controller.totalTrophyCount})',
          icon: Icons.emoji_events,
          dividerAbove: true,
          onRun: _showTrophyCabinet,
        ),
      AppMenuEntry(
        label: 'App settings…',
        icon: Icons.settings,
        dividerAbove: true,
        onRun: () => openAppSettings(context),
      ),
    ];
  }

  /// App-bar file button: shows the loaded file name and opens a menu with
  /// recent files, a file browser, paste-from-clipboard, and — once something
  /// is loaded — the way back out to the start screen.
  Widget _buildOpenPgnMenuButton(String fileName) {
    final hasCollection =
        _controller.allGames.isNotEmpty || _controller.filePath != null;
    return PopupMenuButton<String>(
      tooltip: 'Open PGN — recent files, browse, or paste',
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
}
